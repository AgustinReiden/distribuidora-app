-- =========================================================================
-- La merma baja el stock en una transaccion
--
-- EL BUG (issue #518)
-- ---------------------------------------------------------------------------
-- La merma manual se armaba con TRES requests desde el navegador:
--
--   1. INSERT en mermas_stock con stock_anterior/stock_nuevo calculados en el
--      cliente (ModalMermaStock: `stockNuevo = producto.stock - cantidad`).
--   2. UPDATE productos SET stock = <valor ABSOLUTO>.
--   3. si (2) fallaba, un DELETE de la fila de (1) como compensacion a mano.
--
-- El (2) es el mismo bug que el incidente de la ficha de producto del 19/08
-- (ver useActualizarProductoMutation.stock.test.tsx): un valor absoluto
-- calculado sobre un snapshot. Dos mermas de 10 sobre stock 100, cargadas al
-- mismo tiempo desde dos pantallas, escriben las dos `stock = 90`: quedan dos
-- filas de merma por 20 unidades y el stock bajo 10. Rompe STK-A, que exige
-- que productos.stock sea la ultima fila de stock_historico.
--
-- Y el (3) no es una transaccion: si el DELETE compensatorio falla -- o si se
-- cierra la pestaña entre (1) y (2) -- queda una merma sin baja de stock.
--
-- El camino correcto ya existia al lado: dar_de_baja_lote (mig 224) hace
-- FOR UPDATE + INSERT + `stock = stock - N` en una sola transaccion, con el
-- origen seteado para el ledger. Esto es lo mismo para la merma manual.
--
-- POR QUE ALCANZA CON ETIQUETAR EL ORIGEN Y NO HAY QUE TOCAR producto_lotes
-- ---------------------------------------------------------------------------
-- Una merma BAJA stock. sincronizar_lotes_stock (mig 223) consume FEFO en toda
-- bajada, mire o no el origen -- la lista blanca de origenes es solo para el
-- camino que DEVUELVE unidades. Asi que aca no hay que tocar producto_lotes:
-- el trigger come primero de la bolsa sin vencimiento y recien despues del lote
-- que vence antes, que es la respuesta correcta para "se rompio una caja".
--
-- El `app.stock_origen = 'merma'` igual va, y es la otra mitad del arreglo:
-- hasta hoy TODA merma manual entraba al ledger como `origen = 'auto'` y sin
-- usuario_id, porque el UPDATE salia crudo desde el navegador. Un movimiento
-- fantasma, imposible de atribuir desde la app.
--
-- EL GATE ES admin, QUE ES LO QUE HOY FUNCIONA
-- ---------------------------------------------------------------------------
-- Siendo SECURITY DEFINER, esta funcion se saltea la RLS y pasa a ser el gate
-- entero. El gate de hoy es la INTERSECCION de las dos politicas que la merma
-- manual toca:
--
--   mt_mermas_stock_insert : es_admin() OR es_transportista()
--   mt_productos_update    : es_admin() OR rol = 'deposito'
--
-- Un transportista puro inserta la fila y NO puede bajar el stock; un deposito
-- puro baja el stock y NO puede insertar la fila. O sea: hoy la merma manual la
-- completa admin y nadie mas -- que es tambien lo unico que ofrece la UI, donde
-- el boton esta detras de `isAdmin` (rol === 'admin'). Ademas no hay ningun
-- perfil con rol 'deposito' en la base.
--
-- Encargado queda AFUERA a proposito. Hay 5 roturas historicas de un encargado
-- (2026-05 a 2026-07), de cuando las politicas eran otras: hoy no puede, y
-- abrirle la puerta seria un cambio de producto, no el arreglo de esta
-- concurrencia. Si se decide, es una linea.
--
-- LOS MOTIVOS DEL MOTOR DE PROMOCIONES NO SE PUEDEN CARGAR A MANO
-- ---------------------------------------------------------------------------
-- 'promociones' y 'promociones_reversion' los escribe el motor de promociones
-- como contrapartida de un regalo ya contabilizado en el pedido, y por eso el
-- reporte gerencial (mig 130) los EXCLUYE del total de mermas. Una perdida real
-- cargada a mano con ese motivo desaparece de todos los KPIs sin dejar rastro.
-- Hasta hoy eso vivia solo en un comentario del modal (ModalMermaStock.tsx);
-- ahora que hay una funcion, vive donde se puede hacer cumplir.
-- =========================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.registrar_merma_manual(
  p_producto_id   bigint,
  p_cantidad      integer,
  p_motivo        text,
  p_observaciones text   DEFAULT NULL,
  p_sucursal_id   bigint DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
  v_rol      text;
  v_obs      text;
  v_stock    integer;
  v_merma    public.mermas_stock%ROWTYPE;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  -- p_sucursal_id NO elige la sucursal: la elige current_sucursal_id(), que
  -- valida la membresia contra usuario_sucursales. El parametro esta para que
  -- el replay offline -- que reenvia una merma cargada en otra sucursal --
  -- choque con un error claro en vez de escribir en la sucursal equivocada.
  IF p_sucursal_id IS NOT NULL AND p_sucursal_id <> v_sucursal THEN
    RAISE EXCEPTION 'La merma es de la sucursal % y la sesion esta en la %: cambia de sucursal y reintenta',
      p_sucursal_id, v_sucursal;
  END IF;

  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol <> 'admin' THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin';
  END IF;

  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad a dar de baja tiene que ser mayor a 0';
  END IF;

  IF p_motivo IS NULL OR p_motivo NOT IN ('rotura', 'vencimiento', 'robo', 'decomiso',
                                          'devolucion', 'error_inventario', 'muestra', 'otro') THEN
    RAISE EXCEPTION 'Motivo de merma invalido: %', COALESCE(p_motivo, '(vacio)');
  END IF;

  v_obs := NULLIF(btrim(COALESCE(p_observaciones, '')), '');

  -- El FOR UPDATE es todo el arreglo: la segunda merma concurrente espera aca
  -- y lee el stock que dejo la primera, en vez de pisarla con su snapshot.
  SELECT stock INTO v_stock
    FROM public.productos
   WHERE id = p_producto_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  IF v_stock IS NULL THEN
    RAISE EXCEPTION 'El producto % no existe en esta sucursal', p_producto_id;
  END IF;

  IF v_stock < p_cantidad THEN
    RAISE EXCEPTION 'El stock del producto es % y la baja es de %: dejaria stock negativo',
      v_stock, p_cantidad;
  END IF;

  -- stock_anterior/stock_nuevo salen del valor LOCKEADO, no del cliente.
  -- stock_nuevo = GREATEST(stock_anterior - cantidad, 0) es el invariante
  -- MERMA-B; usuario_id nunca NULL es MERMA-I. El costo lo congela solo
  -- trg_mermas_snapshot_costo (mig 119).
  INSERT INTO public.mermas_stock (
    producto_id, cantidad, motivo, observaciones,
    stock_anterior, stock_nuevo, usuario_id, sucursal_id
  ) VALUES (
    p_producto_id, p_cantidad, p_motivo, v_obs,
    v_stock, GREATEST(v_stock - p_cantidad, 0), auth.uid(), v_sucursal
  )
  RETURNING * INTO v_merma;

  -- Incremental, nunca absoluto, y etiquetado para el ledger.
  PERFORM set_config('app.stock_origen',   'merma',           true);
  PERFORM set_config('app.stock_ref_tipo', 'mermas_stock',    true);
  PERFORM set_config('app.stock_ref_id',   v_merma.id::text,  true);
  PERFORM set_config('app.stock_user_id',  auth.uid()::text,  true);

  UPDATE public.productos
     SET stock = stock - p_cantidad,
         updated_at = now()
   WHERE id = p_producto_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object(
    'ok',    true,
    'merma', to_jsonb(v_merma),
    'stock', v_stock - p_cantidad
  );
END;
$fn$;

COMMENT ON FUNCTION public.registrar_merma_manual(bigint, integer, text, text, bigint) IS
  'Registra una merma manual: FOR UPDATE sobre el producto, INSERT en '
  'mermas_stock con stock_anterior/stock_nuevo server-side y UPDATE incremental '
  'del stock etiquetado app.stock_origen = merma, todo en una transaccion. '
  'Reemplaza las tres requests del cliente que se pisaban entre si. mig 232.';

-- ---------------------------------------------------------------------------
-- Permisos. Una funcion nueva de `public` nace con EXECUTE para PUBLIC y
-- Supabase ademas se lo concede a `anon`: hay que revocar las dos mitades.
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.registrar_merma_manual(bigint, integer, text, text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_merma_manual(bigint, integer, text, text, bigint) TO authenticated;

DO $verif$
DECLARE
  v_acl text;
BEGIN
  SELECT array_to_string(proacl, ',') INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'registrar_merma_manual';

  IF v_acl IS NULL THEN
    RAISE EXCEPTION 'registrar_merma_manual quedo con ACL default (PUBLIC ejecuta)';
  END IF;
  IF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
    RAISE EXCEPTION 'registrar_merma_manual quedo ejecutable por PUBLIC: %', v_acl;
  END IF;
  IF v_acl LIKE '%anon=%' THEN
    RAISE EXCEPTION 'registrar_merma_manual quedo ejecutable por anon: %', v_acl;
  END IF;
  IF v_acl NOT LIKE '%authenticated=X%' THEN
    RAISE EXCEPTION 'registrar_merma_manual no quedo ejecutable por authenticated: %', v_acl;
  END IF;
END
$verif$;

-- Una sola firma: dos sobrecargas con rangos [obligatorios, total] superpuestos
-- hacen que PostgREST tire PGRST203 en runtime, invisible para tsc y los tests.
DO $unica$
DECLARE
  v_n integer;
BEGIN
  SELECT count(*) INTO v_n
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'registrar_merma_manual';

  IF v_n <> 1 THEN
    RAISE EXCEPTION 'registrar_merma_manual quedo con % firmas: PostgREST no va a saber cual llamar', v_n;
  END IF;
END
$unica$;

COMMIT;

-- =========================================================================
-- El lote vencido que el proveedor se lleva es un credito, no una perdida
--
-- EL PROBLEMA
-- -----------
-- Hoy el unico camino para sacar de circulacion un lote vencido es
-- `dar_de_baja_lote` (mig 224), que lo escribe en `mermas_stock` con motivo
-- 'vencimiento'. Eso es correcto cuando la mercaderia se tira: es una perdida
-- de la distribuidora y tiene que aparecer en el costo de las mermas.
--
-- Pero cuando el proveedor se lleva lo vencido y lo acredita, la distribuidora
-- NO perdio nada: tiene un credito contra la proxima factura. Registrarlo como
-- merma infla `reporte_mermas` y el KPI de mermas del gerencial con plata que
-- vuelve, que es exactamente lo que el issue #564 pedia separar.
--
-- LA MITAD DEL CIRCUITO YA EXISTIA
-- --------------------------------
-- `notas_credito` / `nota_credito_items` y `registrar_nota_credito` (viva desde
-- el baseline, ultimo parche en la mig 236) ya hacen el credito de compra: baja
-- `productos.stock` y NO escribe en `mermas_stock`. Lo que no hacen es trabajar
-- a nivel de LOTE:
--
--   * no descuentan `producto_lotes.cantidad_restante`, asi que el lote vencido
--     seguiria en el panel despues de devuelto; y
--   * no etiquetan `app.stock_origen`, asi que su baja entra al ledger como
--     'auto' (hueco conocido de STK-D, que esta migracion no repite pero
--     tampoco arregla: tocar la RPC de compras es otro alcance).
--
-- Por eso esto es una FUNCION NUEVA y no una sobrecarga de
-- `registrar_nota_credito`: dos sobrecargas con rangos [obligatorios, total]
-- superpuestos hacen que PostgREST no sepa cual llamar y tire PGRST203 en
-- runtime, invisible para `tsc` y para los tests (Trampa 5 de CLAUDE.md). Y
-- tampoco comparten forma: una habla de una factura entera con una lista de
-- items, esta de UN lote y una cantidad.
--
-- EL ORDEN IMPORTA: PRIMERO EL LOTE, DESPUES EL STOCK
-- ---------------------------------------------------
-- Es el mismo orden que `dar_de_baja_lote`, y por el mismo motivo:
--
--   bolsa_despues = (stock - N) - (asignado - N) = stock - asignado = bolsa
--
-- La bolsa queda igual, asi que cuando `trg_lotes_sincronizar` (mig 223) corra
-- no va a encontrar excedente y no va a consumir un segundo lote por FEFO. Al
-- revez -- stock primero -- el trigger se comeria el lote que vence antes, que
-- puede no ser este. Es el mismo error que la mig 229 documento para
-- `anular_compra_atomica`.
--
-- 'lote_devuelto_proveedor' NO VA A LA LISTA BLANCA
-- -------------------------------------------------
-- La lista blanca de `sincronizar_lotes_stock` solo se consulta en la rama
-- POSITIVA (el ELSIF), o sea que solo importa para lo que DEVUELVE stock. Esto
-- es una BAJA: la mercaderia se va del deposito y no vuelve. Agregar el origen
-- ahi no cambiaria nada hoy y mentiria manana. Queda escrito aca igual que la
-- mig 234 lo dejo escrito para 'salvedad_merma'.
--
-- LO QUE ESTO NO HACE
-- -------------------
--   * NO escribe en `mermas_stock`. Es el punto de la migracion.
--   * NO recalcula `productos.costo_promedio` ni el CMV: forward-only, igual
--     que `registrar_nota_credito`. La mercaderia devuelta ya esta valuada al
--     costo con el que entro, y mover el promedio hacia atras es justo lo que
--     la mig 236 documento que no se hace sin snapshot.
--   * NO inventa proveedor ni costo. Un lote manual (`compra_id IS NULL`) no
--     tiene factura contra la cual acreditar y se rechaza con un mensaje que
--     dice cual es la otra puerta.
-- =========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1 - La RPC
-- ---------------------------------------------------------------------------

-- Cuatro parametros y NINGUN default: una sola firma, rango [4,4], sin
-- posibilidad de PGRST203 contra nada. El front manda los cuatro siempre.
CREATE OR REPLACE FUNCTION public.registrar_nota_credito_lote(
  p_lote_id     bigint,
  p_cantidad    numeric,
  p_numero_nota text,
  p_motivo      text
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursal   bigint := public.current_sucursal_id();
  v_rol        text;
  v_lote       record;
  v_cant       integer;
  v_stock      integer;
  v_costo      numeric;
  v_tasa_iva   numeric;
  v_subtotal   numeric;
  v_iva        numeric;
  v_comprado   integer;
  v_acreditado integer;
  v_nota_id    bigint;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  -- Mismo gate que dar_de_baja_lote: ver y sacar de circulacion son dos
  -- permisos distintos. Deposito mira lo que se le vence; administracion
  -- decide si se tira o se devuelve.
  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;

  -- numeric en la firma porque PostgREST manda los numeros de JSON sin tipo,
  -- pero las unidades son enteras: `nota_credito_items.cantidad` es integer y
  -- `producto_lotes.cantidad_restante` tambien. Redondear en silencio haria que
  -- el lote y la nota digan cosas distintas.
  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad a devolver tiene que ser mayor a 0';
  END IF;
  IF p_cantidad <> trunc(p_cantidad) THEN
    RAISE EXCEPTION 'La cantidad a devolver tiene que ser un numero entero de unidades: %', p_cantidad;
  END IF;
  v_cant := p_cantidad::integer;

  SELECT * INTO v_lote
    FROM public.producto_lotes
   WHERE id = p_lote_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El lote % no existe en esta sucursal', p_lote_id;
  END IF;

  -- Un lote manual es stock que ya estaba cuando se prendio la feature: no
  -- nacio de una factura, asi que no hay proveedor a quien acreditarle ni costo
  -- de compra del cual sacar el importe. Inventar cualquiera de los dos seria
  -- peor que no poder hacerlo.
  IF v_lote.compra_id IS NULL THEN
    RAISE EXCEPTION 'Este lote no tiene compra de origen: no se le puede generar una nota de crédito, sólo dar de baja';
  END IF;

  IF v_cant > v_lote.cantidad_restante THEN
    RAISE EXCEPTION 'El lote tiene % unidades: no se pueden devolver %',
      v_lote.cantidad_restante, v_cant;
  END IF;

  -- No hace falta chequear que la compra no este cancelada: cancelarla dispara
  -- `borrar_lotes_compra_cancelada` (mig 224) y el lote no existiria.

  -- El FOR UPDATE sobre las lineas de la compra es lo que SERIALIZA contra la
  -- otra puerta: dos notas simultaneas sobre la misma compra -- una por lote y
  -- una por factura entera -- leerian el mismo "ya acreditado" y acreditarian
  -- el doble. Es el mismo candado que la mig 236 le puso a
  -- `registrar_nota_credito`, y por eso las dos puertas se ven entre si.
  PERFORM 1 FROM public.compra_items
   WHERE compra_id = v_lote.compra_id
     AND producto_id = v_lote.producto_id
     AND sucursal_id = v_sucursal
   ORDER BY id
     FOR UPDATE;

  -- El costo sale de la factura de origen, que es la misma lectura que hace
  -- `ModalNotaCredito` para una compra entera: `costo_unitario` bruto
  -- pre-bonificacion, y el IVA por la alicuota que tenia CADA linea (mig 177),
  -- no un 21% fijo. Contra una factura mixta, acreditar 21% sobre una linea
  -- exenta inventa credito fiscal que el proveedor nunca facturo.
  --
  -- La misma factura puede traer el mismo producto en dos renglones con costos
  -- distintos, y `producto_lotes` habla de producto y fecha, no de renglon: no
  -- hay forma de saber de cual salio. El promedio ponderado de esos renglones
  -- es la respuesta honesta, y es la misma plata cuando hay un solo renglon
  -- (el caso normal). Los COALESCE espejan los defaults del front:
  -- `porcentaje_iva ?? 21` para las lineas previas a la mig 113.
  SELECT SUM(ci.cantidad)::integer,
         SUM(ci.cantidad * ci.costo_unitario) / NULLIF(SUM(ci.cantidad), 0),
         SUM(ci.cantidad * ci.costo_unitario
             * CASE WHEN ci.condicion_iva = 'gravado'
                    THEN COALESCE(ci.porcentaje_iva, 21) ELSE 0 END)
           / NULLIF(SUM(ci.cantidad * ci.costo_unitario), 0)
    INTO v_comprado, v_costo, v_tasa_iva
    FROM public.compra_items ci
   WHERE ci.compra_id = v_lote.compra_id
     AND ci.producto_id = v_lote.producto_id
     AND ci.sucursal_id = v_sucursal;

  IF v_comprado IS NULL THEN
    RAISE EXCEPTION 'La compra % ya no tiene ninguna línea de este producto: no se puede resolver el costo de la nota de crédito',
      v_lote.compra_id;
  END IF;

  -- El tope de lo acreditable es el mismo que el de la factura entera: no se
  -- puede acreditar mas unidades de las que se compraron. Sin esto, acreditar
  -- la compra completa por un lado y el lote por el otro acreditaria el doble
  -- -- la nota de compra baja stock pero no toca lotes, asi que el contador del
  -- lote sigue en pie y habilitaria la segunda vuelta.
  SELECT COALESCE(SUM(nci.cantidad), 0)::integer INTO v_acreditado
    FROM public.nota_credito_items nci
    JOIN public.notas_credito nc
      ON nc.id = nci.nota_credito_id AND nc.sucursal_id = nci.sucursal_id
   WHERE nc.compra_id = v_lote.compra_id
     AND nc.sucursal_id = v_sucursal
     AND nci.producto_id = v_lote.producto_id;

  IF v_cant > v_comprado - v_acreditado THEN
    RAISE EXCEPTION 'La compra trajo % unidades de este producto y ya se acreditaron %: no se pueden acreditar %',
      v_comprado, v_acreditado, v_cant;
  END IF;

  SELECT stock INTO v_stock
    FROM public.productos
   WHERE id = v_lote.producto_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  IF v_stock IS NULL THEN
    RAISE EXCEPTION 'El producto % no existe en esta sucursal', v_lote.producto_id;
  END IF;
  IF v_stock < v_cant THEN
    RAISE EXCEPTION 'El stock del producto es % y la devolución es de %: dejaría stock negativo',
      v_stock, v_cant;
  END IF;

  v_subtotal := round(v_cant * v_costo, 2);
  v_iva      := round(v_subtotal * v_tasa_iva / 100, 2);

  -- `fecha` en hora argentina y no CURRENT_DATE: la base corre en UTC y despues
  -- de las 21:00 ART el default fecharia la nota al dia siguiente (mig 182). No
  -- se toca el default de la tabla ni la RPC de compras: fuera de alcance.
  INSERT INTO public.notas_credito (
    compra_id, numero_nota, fecha, subtotal, iva, total, motivo, usuario_id, sucursal_id
  ) VALUES (
    v_lote.compra_id,
    NULLIF(btrim(COALESCE(p_numero_nota, '')), ''),
    (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
    v_subtotal, v_iva, v_subtotal + v_iva,
    COALESCE(NULLIF(btrim(COALESCE(p_motivo, '')), ''),
             'Devolución al proveedor del lote vencido el '
               || to_char(v_lote.fecha_vencimiento, 'DD/MM/YYYY')),
    auth.uid(), v_sucursal
  )
  RETURNING id INTO v_nota_id;

  INSERT INTO public.nota_credito_items (
    nota_credito_id, producto_id, cantidad, costo_unitario, subtotal,
    stock_anterior, stock_nuevo, sucursal_id
  ) VALUES (
    v_nota_id, v_lote.producto_id, v_cant, round(v_costo, 2), v_subtotal,
    v_stock, GREATEST(v_stock - v_cant, 0), v_sucursal
  );

  -- 1) el lote. ANTES del stock: ver el encabezado.
  UPDATE public.producto_lotes
     SET cantidad_restante = cantidad_restante - v_cant
   WHERE id = p_lote_id;

  -- 2) el stock, etiquetado para el ledger. La referencia apunta a la NOTA y no
  --    al lote: la nota es el comprobante, y desde ella se llega al lote por la
  --    compra. `registrar_nota_credito` no etiqueta nada y sus bajas entran como
  --    'auto'; esta puerta no repite ese hueco.
  PERFORM set_config('app.stock_origen',   'lote_devuelto_proveedor', true);
  PERFORM set_config('app.stock_ref_tipo', 'notas_credito',           true);
  PERFORM set_config('app.stock_ref_id',   v_nota_id::text,           true);
  PERFORM set_config('app.stock_user_id',  auth.uid()::text,          true);

  UPDATE public.productos
     SET stock = stock - v_cant,
         updated_at = now()
   WHERE id = v_lote.producto_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object(
    'ok',                true,
    'lote_id',           p_lote_id,
    'nota_credito_id',   v_nota_id,
    'compra_id',         v_lote.compra_id,
    'cantidad',          v_cant,
    'cantidad_restante', v_lote.cantidad_restante - v_cant,
    'stock',             v_stock - v_cant,
    'costo_unitario',    round(v_costo, 2),
    'subtotal',          v_subtotal,
    'iva',               v_iva,
    'total',             v_subtotal + v_iva
  );
END;
$fn$;

COMMENT ON FUNCTION public.registrar_nota_credito_lote(bigint, numeric, text, text) IS
  'Devuelve al proveedor unidades de un lote y las acredita: nota de credito '
  'contra la compra de origen, SIN fila en mermas_stock. Descuenta el lote antes '
  'que el stock para que el trigger de la mig 223 no consuma otro lote por FEFO, '
  'y etiqueta la baja como lote_devuelto_proveedor. mig 253, issue #564.';

-- ---------------------------------------------------------------------------
-- 2 - Permisos
--
-- Toda funcion nueva de `public` nace con EXECUTE para PUBLIC y Supabase se lo
-- concede a `anon` por separado: hay que revocar las DOS mitades en la misma
-- migracion, porque `GRANT TO authenticated` no lo revierte.
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.registrar_nota_credito_lote(bigint, numeric, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_nota_credito_lote(bigint, numeric, text, text) TO authenticated;

DO $verif$
DECLARE
  v_acl text;
  v_n   int;
BEGIN
  -- Una sola firma: si quedaran dos, PostgREST tiraria PGRST203 en runtime.
  SELECT count(*) INTO v_n
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname = 'registrar_nota_credito_lote';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'registrar_nota_credito_lote quedo con % firmas en vez de 1', v_n;
  END IF;

  SELECT array_to_string(proacl, ',') INTO v_acl
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname = 'registrar_nota_credito_lote';

  IF v_acl IS NULL THEN
    RAISE EXCEPTION 'registrar_nota_credito_lote quedo con ACL default (PUBLIC ejecuta)';
  END IF;
  IF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
    RAISE EXCEPTION 'registrar_nota_credito_lote quedo ejecutable por PUBLIC: %', v_acl;
  END IF;
  IF v_acl LIKE '%anon=%' THEN
    RAISE EXCEPTION 'registrar_nota_credito_lote quedo ejecutable por anon: %', v_acl;
  END IF;
  IF v_acl NOT LIKE '%authenticated=X%' THEN
    RAISE EXCEPTION 'registrar_nota_credito_lote no quedo ejecutable por authenticated: %', v_acl;
  END IF;

  IF has_function_privilege('anon',
       'public.registrar_nota_credito_lote(bigint, numeric, text, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon puede ejecutar registrar_nota_credito_lote';
  END IF;
END
$verif$;

-- ---------------------------------------------------------------------------
-- 3 - El origen nuevo NO entra a la lista blanca del trigger
--
--     Escrito como check y no solo como comentario, igual que la mig 234 con
--     'salvedad_merma': si alguien lo agrega "para que sea simetrico con las
--     otras devoluciones", esto se pone rojo y explica por que no.
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname = 'sincronizar_lotes_stock';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'no existe sincronizar_lotes_stock: el modelo de lotes cambio';
  END IF;

  -- La lista blanca solo se mira en la rama POSITIVA. 'lote_devuelto_proveedor'
  -- es una BAJA: la mercaderia se va y no vuelve.
  IF v_def LIKE '%''lote_devuelto_proveedor''%' THEN
    RAISE EXCEPTION 'lote_devuelto_proveedor no va en sincronizar_lotes_stock: es una baja, y la lista blanca solo se consulta cuando el stock SUBE';
  END IF;
END
$verif$;

-- ---------------------------------------------------------------------------
-- 4 - Ensayo funcional, sobre el cuerpo vivo y con ROLLBACK.
--
--     En prod `producto_lotes` tiene cero filas, asi que el ensayo crea su
--     propio producto, su compra y su lote por el camino real
--     (`sincronizar_lotes_compra`) y lo deshace todo con el RAISE del final del
--     bloque interno (molde de las migs 236/240). Solo avanzan las secuencias.
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_uid           uuid;
  v_suc           bigint;
  v_fallas        text := '';
  -- A - la devolucion
  v_restante_a    integer;
  v_stock_a       integer;
  v_filas_merma_a integer;
  v_mermas_a      integer;
  v_merma_costo_a numeric;
  v_nc_total      numeric;
  v_nc_costo      numeric;
  v_nc_cant       integer;
  v_origen_a      text;
  v_ref_a         boolean;
  -- B - el lote sin compra
  v_err_b         text;
  v_ok_b          boolean;
BEGIN
  SELECT p.id, us.sucursal_id INTO v_uid, v_suc
    FROM perfiles p
    JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.es_default
   WHERE p.rol = 'admin'
   ORDER BY p.id
   LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'mig253: no hay ningun admin con sucursal por defecto; el ensayo no puede correr.';
  END IF;

  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

    DECLARE
      v_prod     bigint;
      v_prod_man bigint;
      v_compra   bigint;
      v_lote     bigint;
      v_lote_man bigint;
      v_res      jsonb;
      v_merma_0  integer;
      v_costo_0  numeric;
      v_venc     date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - 5;
    BEGIN
      -- La foto de las mermas ANTES de todo. Una devolucion al proveedor no
      -- tiene que mover ni una fila ni un peso de este reporte.
      SELECT count(*)::integer, COALESCE(SUM(mv.costo_total), 0)
        INTO v_merma_0, v_costo_0
        FROM mermas_valorizadas(
               (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - 30,
               (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
               ARRAY[v_suc]) mv;

      INSERT INTO productos (nombre, precio, sucursal_id, stock)
        VALUES ('ZZZ nc_lote ensayo', 100, v_suc, 0) RETURNING id INTO v_prod;

      -- 10 unidades a $10 + IVA 21%: el costo que la nota tiene que copiar.
      v_res := registrar_compra_completa(NULL, 'ZZZ nc_lote', 'ZZZ-NCL', CURRENT_DATE,
                 100, 21, 0, 121, 'efectivo', 'ensayo nc_lote', v_uid,
                 jsonb_build_array(jsonb_build_object(
                   'producto_id', v_prod, 'cantidad', 10, 'costo_unitario', 10, 'subtotal', 100,
                   'bonificacion', 0, 'porcentaje_iva', 21, 'impuestos_internos', 0,
                   'condicion_iva', 'gravado')),
                 'FC', 0, 0, 0, 0, '[]'::jsonb, '{}'::jsonb, 0);
      IF NOT (v_res->>'success')::boolean THEN
        RAISE EXCEPTION 'A · el alta de compra fallo: %', v_res->>'error';
      END IF;
      v_compra := (v_res->>'compra_id')::bigint;

      -- El lote por el camino real, no con un INSERT a mano.
      PERFORM sincronizar_lotes_compra(v_compra, jsonb_build_array(jsonb_build_object(
                'producto_id', v_prod, 'fecha_vencimiento', v_venc, 'cantidad', 10)));

      SELECT id INTO v_lote
        FROM producto_lotes
       WHERE compra_id = v_compra AND producto_id = v_prod AND sucursal_id = v_suc;
      IF v_lote IS NULL THEN
        RAISE EXCEPTION 'A · el lote no se creo';
      END IF;

      -------------------------------------------------------------------
      -- A · devolver 3 de las 10
      -------------------------------------------------------------------
      v_res := registrar_nota_credito_lote(v_lote, 3, 'ZZZ-NC-1', 'ensayo nc_lote');

      SELECT cantidad_restante INTO v_restante_a FROM producto_lotes WHERE id = v_lote;
      SELECT stock INTO v_stock_a FROM productos WHERE id = v_prod AND sucursal_id = v_suc;

      SELECT count(*)::integer INTO v_filas_merma_a
        FROM mermas_stock WHERE producto_id = v_prod AND sucursal_id = v_suc;

      SELECT count(*)::integer - v_merma_0,
             COALESCE(SUM(mv.costo_total), 0) - v_costo_0
        INTO v_mermas_a, v_merma_costo_a
        FROM mermas_valorizadas(
               (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - 30,
               (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
               ARRAY[v_suc]) mv;

      SELECT nc.total, nci.costo_unitario, nci.cantidad
        INTO v_nc_total, v_nc_costo, v_nc_cant
        FROM notas_credito nc
        JOIN nota_credito_items nci ON nci.nota_credito_id = nc.id
       WHERE nc.id = (v_res->>'nota_credito_id')::bigint;

      SELECT sh.origen, sh.referencia_tipo = 'notas_credito'
             AND sh.referencia_id = (v_res->>'nota_credito_id')::bigint
        INTO v_origen_a, v_ref_a
        FROM stock_historico sh
       WHERE sh.producto_id = v_prod AND sh.diferencia < 0
       ORDER BY sh.id DESC LIMIT 1;

      -------------------------------------------------------------------
      -- B · un lote manual no tiene factura contra la cual acreditar
      --
      --     Sobre un producto aparte: en el de arriba la bolsa quedo en 0
      --     (stock 7, lote 7) y `crear_lote_manual` no tendria de donde
      --     etiquetar.
      -------------------------------------------------------------------
      INSERT INTO productos (nombre, precio, sucursal_id, stock)
        VALUES ('ZZZ nc_lote ensayo manual', 100, v_suc, 5) RETURNING id INTO v_prod_man;

      v_res := crear_lote_manual(v_prod_man, v_venc + 60, 1);
      v_lote_man := (v_res->>'lote_id')::bigint;

      BEGIN
        PERFORM registrar_nota_credito_lote(v_lote_man, 1, 'ZZZ-NC-2', 'ensayo nc_lote');
        v_ok_b := true;
      EXCEPTION WHEN OTHERS THEN
        v_ok_b  := false;
        v_err_b := SQLERRM;
      END;
    END;

    RAISE EXCEPTION 'mig253_rollback_del_ensayo';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'mig253_rollback_del_ensayo' THEN
      RAISE EXCEPTION 'mig253 · el ensayo funcional exploto: %', SQLERRM;
    END IF;
  END;

  -- A
  IF v_restante_a IS DISTINCT FROM 7 THEN
    v_fallas := v_fallas || format(' [A: el lote quedo en %s y tenia que quedar en 7]', v_restante_a);
  END IF;
  IF v_stock_a IS DISTINCT FROM 7 THEN
    v_fallas := v_fallas || format(' [A: el stock quedo en %s y tenia que quedar en 7]', v_stock_a);
  END IF;
  IF v_filas_merma_a IS DISTINCT FROM 0 THEN
    v_fallas := v_fallas || format(' [A: la devolucion dejo %s filas en mermas_stock]', v_filas_merma_a);
  END IF;
  IF v_mermas_a IS DISTINCT FROM 0 THEN
    v_fallas := v_fallas || format(' [A: la devolucion agrego %s mermas valorizadas]', v_mermas_a);
  END IF;
  IF COALESCE(v_merma_costo_a, 0) <> 0 THEN
    v_fallas := v_fallas || format(' [A: la devolucion movio el costo de mermas en %s]', v_merma_costo_a);
  END IF;
  IF v_nc_cant IS DISTINCT FROM 3 THEN
    v_fallas := v_fallas || format(' [A: el item de la nota quedo en %s unidades]', v_nc_cant);
  END IF;
  IF v_nc_costo IS DISTINCT FROM 10.00 THEN
    v_fallas := v_fallas || format(' [A: el costo de la nota fue %s y el de la compra era 10]', v_nc_costo);
  END IF;
  IF v_nc_total IS DISTINCT FROM 36.30 THEN
    v_fallas := v_fallas || format(' [A: el total de la nota fue %s y tenia que ser 36.30 (3x10 + 21%%)]', v_nc_total);
  END IF;
  IF v_origen_a IS DISTINCT FROM 'lote_devuelto_proveedor' THEN
    v_fallas := v_fallas || format(' [A: el ledger anoto origen "%s"]', v_origen_a);
  END IF;
  IF NOT COALESCE(v_ref_a, false) THEN
    v_fallas := v_fallas || ' [A: la fila del ledger no apunta a la nota de credito]';
  END IF;
  -- B
  IF COALESCE(v_ok_b, true) THEN
    v_fallas := v_fallas || ' [B: el lote sin compra de origen no fue rechazado]';
  END IF;
  IF v_err_b IS NULL OR v_err_b NOT LIKE '%no tiene compra de origen%' THEN
    v_fallas := v_fallas || format(' [B: el error fue "%s" en vez del mensaje del lote sin compra]', v_err_b);
  END IF;

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig253 · el ensayo funcional encontro:%', v_fallas;
  END IF;

  RAISE NOTICE 'mig253 · ensayo funcional OK: lote=% stock=% mermas+=% nota=% (costo % x %) origen=% · rechazo="%"',
    v_restante_a, v_stock_a, v_mermas_a, v_nc_total, v_nc_costo, v_nc_cant, v_origen_a, v_err_b;
END
$ensayo$;

COMMIT;

-- Anular una salvedad tambien anula su merma
--
-- Decision #621. Habia DOS caminos para "anular" una salvedad y hacian cosas
-- distintas:
--
--   · `anular_salvedad(id, notas)` restituye la linea del pedido, recalcula los
--     totales y corrige el stock. No la llamaba NADIE: no aparece en `src/` ni
--     en las edge functions.
--   · `resolver_salvedad(id, 'anulada', ...)` sólo escribe
--     `estado_resolucion = 'anulada'` y una fila de historial. Eso es lo que
--     disparaba la opcion "Anulada" del picker de ModalResolverSalvedad.
--
-- La segunda deja la plata y el stock donde estaban y ademas TRABA la primera
-- para siempre: `anular_salvedad` empieza con `IF estado = 'anulada' THEN 'Ya
-- anulada'`. En prod no hay ni una salvedad anulada sobre 251, asi que no hay
-- nada que reparar: alcanza con cerrar la puerta antes de que entre la primera.
--
-- EL AGUJERO NUEVO (verificacion del 15/09)
--
--   Desde la mig 234 una salvedad por `producto_danado` / `producto_vencido`
--   deja NETO CERO en `productos.stock` --+N con origen 'salvedad_merma' a la
--   bolsa, -N con origen 'merma' de la bolsa-- y UNA fila en `mermas_stock`.
--   `anular_salvedad` no menciona `mermas_stock` (verificado en su cuerpo vivo)
--   y su unica correccion de stock es
--
--       IF v_salvedad.stock_devuelto THEN stock = stock - cantidad_afectada
--
--   rama que para esos dos motivos NO entra, porque `stock_devuelto` sólo se
--   prende para 'cliente_rechaza' / 'error_pedido' / 'diferencia_precio'.
--   Resultado: al anular, la linea vuelve a cobrarse --las N unidades se
--   facturan-- y la merma sigue viva --las mismas N unidades se declaran
--   perdidas--. N unidades contadas dos veces.
--
-- EL NUMERO NO SE MUEVE, Y ESO ES A PROPOSITO
--
--   El pedido de la tarea decia "ajusta productos.stock ... de modo que el neto
--   quede correcto". Medido contra el cuerpo vivo: el neto YA es correcto y
--   tocarlo lo rompe. La cuenta completa, con un producto en 50 y un pedido de
--   10 unidades, salvedad por dañado de 3:
--
--     alta del pedido        stock 50 -> 40   (10 unidades salen a la calle)
--     salvedad por dañado    stock 40 -> 43 -> 40   (+3 'salvedad_merma' a la
--                                              bolsa, -3 'merma' de la bolsa)
--                            mermas_stock: una fila, 3 unidades
--                            el cliente paga 7
--     anulacion              el cliente vuelve a pagar 10
--                            stock: NO se toca. Las 3 unidades ya estan
--                            contadas como salidas, ahora como venta en vez de
--                            como rotura.
--                            mermas_stock: la fila queda ANULADA.
--
--   Sumarle 3 al stock al anular seria contar las mismas 3 unidades dos veces,
--   que es el mismo error del otro lado. Lo que estaba mal nunca fue el stock:
--   era el libro de mermas. El ensayo del punto 7 mide justo eso.
--
--   Corolario para los lotes: no hay movimiento que etiquetar, asi que no hay
--   nada que agregarle a la lista blanca de `sincronizar_lotes_stock` --y el
--   criterio de la 234 (que 'salvedad_merma' quede AFUERA) queda intacto--.
--
-- ANULADA, NO BORRADA
--
--   La fila de `mermas_stock` no se borra: se marca con `anulada_at` /
--   `anulada_por` y `mermas_valorizadas` (mig 238) la deja afuera. Es una linea
--   en UNA funcion, y los dos reportes que consumen esa funcion
--   --`reporte_mermas` y `reporte_gerencial`-- heredan el criterio sin tocarse,
--   que es exactamente para lo que se unifico en la 238. Borrarla hubiera sido
--   mas corto y habria perdido el asiento; una fila negativa de reversion --el
--   patron de 'promociones_reversion'-- habria pedido un motivo nuevo en el
--   CHECK, en MERMA-A, en MERMA-E y en `merma_clasificacion`, y ademas habria
--   exigido mover el stock para no romper MERMA-B, que es justo lo que no hay
--   que hacer.
--
-- COMO ENCUENTRA SU MERMA
--
--   `mermas_stock.salvedad_id`, columna nueva. Hasta hoy el unico vinculo era
--   el texto de `observaciones`, y ni siquiera siempre: `registrar_salvedad`
--   escribe `COALESCE(p_descripcion, 'Salvedad pedido #N: motivo')`, o sea que
--   con descripcion cargada no queda ni el numero de pedido. El backfill de las
--   9 filas historicas es 1:1 exacto por (created_at, producto, sucursal,
--   cantidad, motivo) --las dos filas se escriben en la misma transaccion, asi
--   que comparten `now()`--; verificado en prod antes de escribir esto: 9 de 9,
--   0 ambiguas, 0 sin merma.
--
-- LO QUE ESTA MIGRACION NO HACE
--
--   · No amplia el gate de `anular_salvedad`. Sigue siendo `es_admin_salvedades()`,
--     que es rol = 'admin' a secas. La vista de salvedades la ven admin Y
--     encargado (App.tsx), asi que el boton nuevo se gatea con
--     `puedeAnularSalvedad` = admin, que es el espejo exacto del RPC. Si el dueño
--     quiere que encargado tambien anule, se amplia la RPC, no la UI.
--   · No toca las dos negativas que `anular_salvedad` ya devuelve para las
--     salvedades sobre regalos de promocion: siguen rechazadas.
--
-- Tecnica: parche por ancla sobre el cuerpo vivo (molde de la 241/242).

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Andamio: parche por ancla, con la guarda de "exactamente una vez".
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._migsv_ancla(
  p_funcion regprocedure, p_ancla text, p_nuevo text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(p_ancla, 120);
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · mermas_stock: de que salvedad viene, y si esta anulada.
--
--     La FK es COMPUESTA con sucursal_id, como todas las del aislamiento por
--     sucursal (mig 187 / Trampa 6): una merma de una sucursal no puede colgar
--     de una salvedad de otra. `ON DELETE SET NULL (salvedad_id)` --sólo esa
--     columna, que sucursal_id es NOT NULL--: `eliminar_pedido_completo` borra
--     el pedido y la salvedad se va en cascada, pero la merma SE QUEDA. La
--     mercaderia se rompio igual.
-- ---------------------------------------------------------------------------
ALTER TABLE public.mermas_stock
  ADD COLUMN IF NOT EXISTS salvedad_id BIGINT,
  ADD COLUMN IF NOT EXISTS anulada_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS anulada_por UUID;

COMMENT ON COLUMN public.mermas_stock.salvedad_id IS
  'Salvedad que genero esta merma (mig 244). NULL en las mermas manuales y en las de promociones.';
COMMENT ON COLUMN public.mermas_stock.anulada_at IS
  'Cuando se anulo la salvedad que la genero (mig 244). Con valor, la fila queda fuera de mermas_valorizadas y de los dos reportes que la consumen.';

ALTER TABLE public.mermas_stock
  DROP CONSTRAINT IF EXISTS mermas_stock_salvedad_id_fkey;
ALTER TABLE public.mermas_stock
  ADD CONSTRAINT mermas_stock_salvedad_id_fkey
  FOREIGN KEY (salvedad_id, sucursal_id)
  REFERENCES public.salvedades_items(id, sucursal_id)
  ON DELETE SET NULL (salvedad_id);

ALTER TABLE public.mermas_stock
  DROP CONSTRAINT IF EXISTS mermas_stock_anulada_por_fkey;
ALTER TABLE public.mermas_stock
  ADD CONSTRAINT mermas_stock_anulada_por_fkey
  FOREIGN KEY (anulada_por) REFERENCES public.perfiles(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_mermas_stock_salvedad
  ON public.mermas_stock (salvedad_id)
  WHERE salvedad_id IS NOT NULL;

-- Backfill: las dos filas se escriben en la misma transaccion, asi que
-- comparten `now()` al milisegundo. Medido antes de escribir la migracion: 9
-- salvedades por dañado/vencido, 9 mermas pareadas, 0 ambiguas. El
-- `RAISE EXCEPTION` de abajo es la guarda por si eso dejo de ser cierto entre
-- la medicion y la aplicacion.
DO $backfill$
DECLARE
  v_total   int;
  v_pareado int;
BEGIN
  SELECT count(*) INTO v_total
    FROM salvedades_items
   WHERE motivo IN ('producto_danado', 'producto_vencido');

  WITH pares AS (
    SELECT s.id AS salvedad_id,
           (SELECT min(m.id) FROM mermas_stock m
             WHERE m.created_at  = s.created_at
               AND m.producto_id = s.producto_id
               AND m.sucursal_id = s.sucursal_id
               AND m.cantidad    = s.cantidad_afectada
               AND m.motivo IN ('rotura', 'vencimiento')
               AND m.salvedad_id IS NULL) AS merma_id
      FROM salvedades_items s
     WHERE s.motivo IN ('producto_danado', 'producto_vencido')
  )
  UPDATE mermas_stock m
     SET salvedad_id = p.salvedad_id
    FROM pares p
   WHERE m.id = p.merma_id;

  GET DIAGNOSTICS v_pareado = ROW_COUNT;

  IF v_pareado <> v_total THEN
    RAISE EXCEPTION 'migsv · el backfill pareo % de % salvedades por dañado/vencido. Revisar a mano antes de seguir.',
      v_pareado, v_total;
  END IF;
  RAISE NOTICE 'migsv · backfill OK: % mermas vinculadas a su salvedad', v_pareado;
END
$backfill$;

-- ---------------------------------------------------------------------------
-- 2 · registrar_salvedad: la merma nace sabiendo de quien es.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._migsv_ancla(
    'public.registrar_salvedad(bigint, bigint, integer, character varying, text, text, boolean, uuid)'::regprocedure,
$ancla$    INSERT INTO mermas_stock (
      producto_id, cantidad, motivo, observaciones,
      stock_anterior, stock_nuevo, usuario_id, sucursal_id
    ) VALUES (
      v_item.producto_id, p_cantidad_afectada,$ancla$,
$nuevo$    INSERT INTO mermas_stock (
      producto_id, cantidad, motivo, observaciones,
      stock_anterior, stock_nuevo, usuario_id, sucursal_id, salvedad_id
    ) VALUES (
      v_item.producto_id, p_cantidad_afectada,$nuevo$);

  PERFORM public._migsv_ancla(
    'public.registrar_salvedad(bigint, bigint, integer, character varying, text, text, boolean, uuid)'::regprocedure,
$ancla$      v_stock_actual, GREATEST(v_stock_actual - p_cantidad_afectada, 0), v_usuario_id, v_sucursal
    ) RETURNING id INTO v_merma_id;$ancla$,
$nuevo$      v_stock_actual, GREATEST(v_stock_actual - p_cantidad_afectada, 0), v_usuario_id, v_sucursal,
      v_salvedad_id
    ) RETURNING id INTO v_merma_id;$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 3 · mermas_valorizadas: una merma anulada no es una merma.
--
--     Una sola linea, y la heredan `reporte_mermas` y `reporte_gerencial`, que
--     son los dos que la consumen. Por eso `totales.costo == kpis.mermas`
--     sigue cerrando por construccion (gate: scripts/check-integridad.mjs).
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._migsv_ancla('public.mermas_valorizadas(date, date, bigint[])'::regprocedure,
$ancla$  WHERE m.sucursal_id = ANY(p_sucursales)$ancla$,
$nuevo$  WHERE m.sucursal_id = ANY(p_sucursales)
    -- mig 244: la merma de una salvedad anulada no es una merma. La fila queda
    -- en la tabla como asiento; para valorizar, no existe.
    AND m.anulada_at IS NULL$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 4 · anular_salvedad: encuentra su merma, la anula, y NO toca el stock.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure := 'public.anular_salvedad(bigint, text)'::regprocedure;
BEGIN
  PERFORM public._migsv_ancla(v_fn,
$ancla$  v_toca_promo BOOLEAN;
BEGIN$ancla$,
$nuevo$  v_toca_promo BOOLEAN;
  v_merma_id BIGINT;
BEGIN$nuevo$);

  -- La busqueda de la merma va ANTES de tocar nada: esta funcion devuelve
  -- `success:false` con RETURN, no con RAISE, asi que un rechazo posterior a un
  -- UPDATE se commitea igual. Los dos rechazos por promocion ya estaban arriba
  -- por la misma razon.
  PERFORM public._migsv_ancla(v_fn,
$ancla$  -- Devolver la linea a su cantidad original no es cargar un pedido nuevo:
  -- el minimo de venta no debe trabarlo (mig 174).
  PERFORM set_config('app.omitir_minimo_venta', '1', true);$ancla$,
$nuevo$  /* mig 244: una salvedad por dañado/vencido dejo una fila en mermas_stock
     (mig 234). Anularla sin anular la merma cuenta las mismas N unidades dos
     veces: facturadas por la linea restituida y perdidas por la merma. Si la
     fila no aparece, se corta ACA -- antes de restituir nada -- y se avisa:
     anular dejando una merma huerfana es descuadrar en silencio. */
  IF v_salvedad.motivo IN ('producto_danado', 'producto_vencido') THEN
    SELECT id INTO v_merma_id
      FROM mermas_stock
     WHERE salvedad_id = p_salvedad_id
       AND sucursal_id = v_sucursal
       AND anulada_at IS NULL
     ORDER BY id
     LIMIT 1;

    IF v_merma_id IS NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'Esta salvedad genero una merma y no se encontro la fila para anularla. Anularla igual dejaria la mercaderia contada dos veces: corregir a mano.',
        'codigo', 'merma_no_encontrada'
      );
    END IF;
  END IF;

  -- Devolver la linea a su cantidad original no es cargar un pedido nuevo:
  -- el minimo de venta no debe trabarlo (mig 174).
  PERFORM set_config('app.omitir_minimo_venta', '1', true);$nuevo$);

  PERFORM public._migsv_ancla(v_fn,
$ancla$  IF v_salvedad.stock_devuelto THEN
    UPDATE productos SET stock = stock - v_salvedad.cantidad_afectada
     WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal;
  END IF;
  UPDATE salvedades_items SET$ancla$,
$nuevo$  IF v_salvedad.stock_devuelto THEN
    -- mig 244: la bajada sale etiquetada. Es una BAJADA, asi que la lista
    -- blanca de trg_lotes_sincronizar ni la mira --el camino de bajada no mira
    -- el origen--: sigue comiendo de la bolsa y despues FEFO, igual que antes.
    -- Lo que cambia es que el ledger deja de decir 'auto' sin referencia.
    PERFORM set_config('app.stock_origen',   'salvedad_anulada',  true);
    PERFORM set_config('app.stock_ref_tipo', 'salvedad',          true);
    PERFORM set_config('app.stock_ref_id',   p_salvedad_id::TEXT, true);
    PERFORM set_config('app.stock_user_id',  COALESCE(v_usuario_id::TEXT, ''), true);

    UPDATE productos SET stock = stock - v_salvedad.cantidad_afectada
     WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal;
  END IF;

  /* mig 244: la merma se anula, y productos.stock NO se toca. La salvedad por
     dañado/vencido dejo neto CERO sobre el stock (+N 'salvedad_merma' a la
     bolsa, -N 'merma' de la bolsa), asi que las N unidades ya estan contadas
     como salidas; al restituir la linea pasan a estar contadas como venta en
     vez de como rotura. Sumarlas de nuevo seria contarlas dos veces, el mismo
     error al reves. Lo que estaba mal era el libro de mermas, no el stock. */
  IF v_merma_id IS NOT NULL THEN
    UPDATE mermas_stock
       SET anulada_at = NOW(), anulada_por = v_usuario_id
     WHERE id = v_merma_id AND sucursal_id = v_sucursal;
  END IF;

  UPDATE salvedades_items SET$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 5 · resolver_salvedad: 'anulada' deja de ser una resolucion.
--
--     Anular mueve stock y plata; las otras seis resoluciones sólo dicen quien
--     se hace cargo del monto. Meterlas en el mismo picker era la puerta por la
--     que se colaba el estado sin los movimientos.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._migsv_ancla('public.resolver_salvedad(bigint, character varying, text, bigint)'::regprocedure,
$ancla$  IF NOT es_admin_salvedades() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin');
  END IF;$ancla$,
$nuevo$  IF NOT es_admin_salvedades() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin');
  END IF;
  -- mig 244 (#621): anular NO es una resolucion. Restituye la linea del pedido,
  -- recalcula los totales y revierte la merma; esta funcion sólo escribe un
  -- estado. Marcar 'anulada' por aca dejaba la plata y el stock donde estaban y
  -- ademas trababa a anular_salvedad para siempre ('Ya anulada').
  IF p_estado_resolucion = 'anulada' THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Anular una salvedad no es una resolucion: mueve stock y plata. Usar la accion "Anular salvedad" (RPC anular_salvedad).',
      'codigo', 'usar_anular_salvedad'
    );
  END IF;$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 6 · auditoria_integridad · SALV-A.
--
--     El gate de la regla: si una salvedad quedo anulada, su merma tiene que
--     estar anulada. Cubre el camino de hoy (la RPC lo hace en la misma
--     transaccion) y el de mañana (un UPDATE a mano sobre salvedades_items:
--     `mt_salvedades_items_update` se lo permite a admin).
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._migsv_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$    ('STK-F','high','funciones de public que suben stock sin declarar app.stock_origen (mig 229)',$ancla$,
$nuevo$    ('SALV-A','high','salvedad anulada con su merma todavia viva (mig 244)',
      (SELECT count(*) FROM mermas_stock m
         JOIN salvedades_items s ON s.id = m.salvedad_id AND s.sucursal_id = m.sucursal_id
        WHERE s.estado_resolucion = 'anulada' AND m.anulada_at IS NULL)),
    ('STK-F','high','funciones de public que suben stock sin declarar app.stock_origen (mig 229)',$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 7 · El ensayo: una salvedad por dañado, anulada, no deja nada atras.
--
--     Producto en 50, pedido por 10, salvedad por dañado de 3, anulacion. Se
--     mide contra el estado ANTERIOR a la salvedad, que es lo que dice la
--     aceptacion: stock 40 todo el tiempo, el pedido vuelve a $1.000 y no queda
--     ninguna merma viva. De paso se verifican los dos rechazos: resolver con
--     'anulada' y anular dos veces.
--
--     El sub-bloque se deshace solo con un SQLSTATE centinela; si una
--     verificacion falla, la excepcion es otra y se propaga.
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_admin    uuid;
  v_suc      bigint;
  v_cliente  bigint;
  v_prod     bigint;
  v_res      jsonb;
  v_pedido   bigint;
  v_item     bigint;
  v_salvedad bigint;
  v_stock    int;
  v_total    numeric;
  v_mermas   int;
  v_valor    int;
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'migsv · el ensayo necesita un admin activo con al menos una sucursal activa';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'migsv · el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  BEGIN
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
    VALUES ('ZZ ensayo mig244', 100, 50, v_suc) RETURNING id INTO v_prod;

    v_res := public.crear_pedido_completo(
      v_cliente, 1000, v_admin,
      jsonb_build_array(jsonb_build_object(
        'producto_id', v_prod, 'cantidad', 10, 'precio_unitario', 100)),
      'ensayo mig244');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'migsv · el ensayo no pudo crear el pedido: %', v_res;
    END IF;
    v_pedido := (v_res->>'pedido_id')::bigint;

    SELECT stock INTO v_stock FROM productos WHERE id = v_prod;
    IF v_stock <> 40 THEN
      RAISE EXCEPTION 'migsv · alta: stock=% (esperado 40)', v_stock;
    END IF;

    SELECT id INTO v_item FROM pedido_items
     WHERE pedido_id = v_pedido AND producto_id = v_prod LIMIT 1;

    -- Salvedad por dañado: neto 0 sobre el stock y una merma (mig 234).
    v_res := public.registrar_salvedad(v_pedido, v_item, 3, 'producto_danado', 'ensayo mig244', NULL, true, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'migsv · el ensayo no pudo registrar la salvedad: %', v_res;
    END IF;
    v_salvedad := (v_res->>'salvedad_id')::bigint;

    SELECT stock INTO v_stock FROM productos WHERE id = v_prod;
    SELECT total INTO v_total FROM pedidos WHERE id = v_pedido;
    SELECT count(*) INTO v_mermas FROM mermas_stock
     WHERE producto_id = v_prod AND anulada_at IS NULL;
    IF v_stock <> 40 OR v_total <> 700 OR v_mermas <> 1 THEN
      RAISE EXCEPTION 'migsv · salvedad: stock=% (40), total=% (700), mermas vivas=% (1)',
        v_stock, v_total, v_mermas;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM mermas_stock WHERE salvedad_id = v_salvedad) THEN
      RAISE EXCEPTION 'migsv · la merma de la salvedad % no quedo vinculada', v_salvedad;
    END IF;

    -- 'anulada' ya no es una resolucion.
    v_res := public.resolver_salvedad(v_salvedad, 'anulada', 'ensayo mig244');
    IF COALESCE((v_res->>'success')::boolean, false)
       OR v_res->>'codigo' IS DISTINCT FROM 'usar_anular_salvedad' THEN
      RAISE EXCEPTION 'migsv · resolver_salvedad acepto "anulada": %', v_res;
    END IF;

    -- La anulacion de verdad.
    v_res := public.anular_salvedad(v_salvedad, 'ensayo mig244');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'migsv · el ensayo no pudo anular la salvedad: %', v_res;
    END IF;

    SELECT stock INTO v_stock FROM productos WHERE id = v_prod;
    SELECT total INTO v_total FROM pedidos WHERE id = v_pedido;
    SELECT count(*) INTO v_mermas FROM mermas_stock
     WHERE producto_id = v_prod AND anulada_at IS NULL;
    SELECT count(*) INTO v_valor FROM public.mermas_valorizadas(
      (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - 1,
      (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date + 1,
      ARRAY[v_suc]) mv WHERE mv.producto_id = v_prod;

    IF v_stock <> 40 OR v_total <> 1000 OR v_mermas <> 0 OR v_valor <> 0 THEN
      RAISE EXCEPTION
        'migsv · anulacion: stock=% (esperado 40), total=% (1000), mermas vivas=% (0), filas valorizadas=% (0)',
        v_stock, v_total, v_mermas, v_valor;
    END IF;

    -- Una salvedad anulada no se re-anula ni se resuelve.
    v_res := public.anular_salvedad(v_salvedad, 'ensayo mig244 bis');
    IF COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'migsv · anular_salvedad acepto una salvedad ya anulada: %', v_res;
    END IF;
    v_res := public.resolver_salvedad(v_salvedad, 'absorcion_empresa', 'ensayo mig244 bis');
    IF COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'migsv · resolver_salvedad acepto una salvedad ya anulada: %', v_res;
    END IF;

    RAISE EXCEPTION 'migsv-ok' USING ERRCODE = '2F000';
  EXCEPTION WHEN SQLSTATE '2F000' THEN
    IF SQLERRM <> 'migsv-ok' THEN RAISE; END IF;
    RAISE NOTICE 'migsv · ensayo OK: la salvedad por dañado anulada deja stock, merma y totales como antes';
  END;
END
$ensayo$;

-- ---------------------------------------------------------------------------
-- 8 · Se saca el andamio.
--     CREATE OR REPLACE preserva la ACL de las cinco funciones parcheadas y no
--     hay ninguna funcion nueva, asi que no hay EXECUTE que revocar.
-- ---------------------------------------------------------------------------
DROP FUNCTION public._migsv_ancla(regprocedure, text, text);

COMMIT;

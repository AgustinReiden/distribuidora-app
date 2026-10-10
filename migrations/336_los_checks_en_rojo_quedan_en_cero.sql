-- #1043 · Los siete checks en rojo de auditoria_integridad(), a cero.
--
-- Estaban en rojo hace meses y sin dueño: un "5 legacy" en rojo esconde un
-- sexto. Se miró cada fila en sólo lectura (2026-10-09) y se eligió, check por
-- check, entre dato roto (se corrige), legacy aceptado (se excluye por id con el
-- porqué) o check mal planteado (se corrige el check). Decisiones del dueño del
-- 2026-10-09 marcadas como tales.
--
-- DATOS
--   MERMA-I (96) · mermas manuales del 07/04 al 03/09 sin usuario: el modal
--     viejo nunca lo mandaba (la 232 lo pasó a registrar_merma_manual, que usa
--     auth.uid()). El UPDATE de stock que hacía ese modal quedó en audit_logs
--     con su usuario: 96 de 96 se atribuyen sin ambigüedad (producto, ±10 s,
--     stock_nuevo). Se completa usuario_id.
--   VENTA-I (4) · los cancelados 629, 663, 682 y 707 (09-13/04) quedaron con
--     total ≠ 0: los canceló una versión vieja de la cancelación. La 235 los
--     dejó para no tocar abril; decisión del dueño: total 0, como los otros 356.
--     Sin pagos ni recorridos: no mueve saldos (un cancelado contribuye 0) y el
--     BEFORE de estado_pago los pasa a 'pagado', como al resto. Se nota en dos
--     lugares: el historial de cada pedido suma dos filas sin autor (total y
--     estado_pago, con fecha de hoy), y en la lista con "ver cancelados" y
--     rango abril bajan en 4 y $45.700 el monto cancelado y los impagos.
--
-- EXCLUSIONES (legacy aceptado, por id)
--   COMIS-01 · 872 y 904: importación de Taco Pozo sin match de vendedor.
--     Decisión del dueño: quedan sin vendedor.
--   COMPRA-A2 · compras 5, 6, 19, 39 y 40: carga incompleta de ene-mar; para
--     arreglarlas hace falta la factura física.
--   COSTO-B · la línea 2401 (pedido 895, producto 186): una venta de marzo de
--     un producto que nunca se compró. Decisión del dueño: se excluye. Se
--     excluye la LÍNEA y no el producto: el 186 sigue activo, y una venta nueva
--     sin costo tiene que verse.
--   VENTA-J · pedido 652: el 2026-05-05 un admin le borró su único ítem y lo
--     marcó entregado en el mismo segundo.
--
-- CHECKS MAL PLANTEADOS
--   VENTA-J · el pedido 4578 es un canje: crear_pedido_cambio_en_ruta lo crea
--     sin ítems por diseño (lo canjeado vive en recorrido_cambios, que cuida
--     CAMBIO-03). Era el único check de venta sin `canal<>'cambio'`; cada canje
--     entregado lo iba a poner en rojo.
--   COSTO-B · miraba costo_sin_iva suelto; "sin costo" es
--     costo_valuacion(...) IS NULL con el snapshot de la línea, lo que deciden
--     los reportes (238, #511). Hoy da lo mismo (1, el 186). Un costo 0 en el
--     snapshot, el promedio o el real cuenta como "con costo" en la cascada;
--     el check sigue esa definición (hoy no hay ninguno).
--
-- STK-D · LOS CAMINOS QUE TODAVÍA NACÍAN 'auto'
--   9.967 filas son de RPCs que las migs 229/232/240/245 ya etiquetaron. Las
--   15 posteriores (28/09-05/10) salen de dos caminos vivos, que se cierran acá:
--     · La ficha de producto: un UPDATE de stock por PostgREST no puede setear
--       app.stock_origen. registrar_cambio_stock() lo reconoce igual que
--       productos_proteger_columnas (current_user = 'authenticated', y
--       pg_trigger_depth() = 1 para que sea el UPDATE directo) y lo asienta como
--       'ajuste_manual' de auth.uid(). Ninguna función INVOKER escribe stock:
--       una RPC sin etiqueta corre como su dueño y sigue cayendo en 'auto'.
--     · registrar_nota_credito: la devolución con ítems baja stock sin
--       etiqueta. Ahora 'nota_credito' → notas_credito/<id>; la referencia es
--       la nota, como en registrar_nota_credito_lote (que usa su propio origen,
--       'lote_devuelto_proveedor').
--   Y uno alcanzable aunque sin uso reciente: ajustar_stock_promocion_completo,
--   ahora 'ajuste_promo' → mermas_stock/<id>. Las tres son bajadas: ninguna va
--   a la lista blanca de trg_lotes_sincronizar.
--   Con eso el check corta en el último 'auto' que existe al aplicar: uno nuevo
--   es un camino que mueve stock sin declarar el origen. (Si una edición de
--   ficha con el cuerpo viejo confirma mientras corre esta migración, la
--   verificación 7.1 la ve y aborta: se reintenta.)
--   Quedan sin etiqueta descontar_stock_atomico (sin caller; issue aparte) y
--   registrar_transferencia (revocada, 1048): si alguien las corre, STK-D lo ve.
--
-- Ensayo: scripts/test-checks-1043.sql (falla antes, pasa después).

BEGIN;

CREATE OR REPLACE FUNCTION public._mig1043_ancla(
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
-- 1 · MERMA-I: el usuario de cada merma, desde audit_logs.
-- ---------------------------------------------------------------------------
DO $merma$
DECLARE
  v_total    int;
  v_unicas   int;
  v_n        int;
BEGIN
  CREATE TEMP TABLE _mig1043_merma ON COMMIT DROP AS
  SELECT m.id, (array_agg(DISTINCT a.usuario_id))[1] AS usuario_id,
         count(DISTINCT a.usuario_id) AS n
    FROM mermas_stock m
    LEFT JOIN audit_logs a
      ON a.tabla = 'productos' AND a.registro_id = m.producto_id::text
     AND a.created_at BETWEEN m.created_at - interval '10 seconds' AND m.created_at + interval '10 seconds'
     AND (a.new_data->>'stock')::numeric = m.stock_nuevo
     AND a.usuario_id IS NOT NULL
   WHERE m.usuario_id IS NULL AND m.motivo NOT IN ('promociones', 'promociones_reversion')
   GROUP BY m.id;

  SELECT count(*), count(*) FILTER (WHERE n = 1) INTO v_total, v_unicas FROM _mig1043_merma;
  IF v_total <> v_unicas THEN
    RAISE EXCEPTION '#1043 · % de % mermas sin usuario no tienen un único autor en audit_logs', v_total - v_unicas, v_total;
  END IF;

  UPDATE mermas_stock m SET usuario_id = t.usuario_id
    FROM _mig1043_merma t WHERE t.id = m.id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RAISE NOTICE '#1043 · MERMA-I: % mermas con su usuario', v_n;
END
$merma$;

-- ---------------------------------------------------------------------------
-- 2 · VENTA-I: los cuatro cancelados de abril, en total 0.
--     `total` y `monto_pagado` van nombrados en el SET: los AFTER OF los miran.
-- ---------------------------------------------------------------------------
DO $cancelados$
DECLARE
  v_n int;
BEGIN
  IF EXISTS (SELECT 1 FROM pagos WHERE pedido_id IN (629, 663, 682, 707))
     OR EXISTS (SELECT 1 FROM pedidos WHERE id IN (629, 663, 682, 707) AND COALESCE(monto_pagado, 0) <> 0) THEN
    RAISE EXCEPTION '#1043 · un cancelado de abril tiene pagos: revisar a mano';
  END IF;

  UPDATE pedidos SET total = 0, monto_pagado = 0
   WHERE id IN (629, 663, 682, 707) AND estado = 'cancelado';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 4 THEN
    RAISE EXCEPTION '#1043 · se esperaban 4 cancelados de abril y se tocaron %', v_n;
  END IF;
END
$cancelados$;

-- ---------------------------------------------------------------------------
-- 3 · El ledger reconoce la edición de stock por REST.
-- ---------------------------------------------------------------------------
SELECT public._mig1043_ancla('public.registrar_cambio_stock()'::regprocedure,
$ancla$BEGIN
  IF OLD.stock IS DISTINCT FROM NEW.stock THEN
    INSERT INTO stock_historico (
      producto_id, stock_anterior, stock_nuevo, origen,
      referencia_tipo, referencia_id, usuario_id, sucursal_id
    ) VALUES (
      NEW.id, OLD.stock, NEW.stock,
      COALESCE(NULLIF(current_setting('app.stock_origen', true), ''), 'auto'),
      NULLIF(current_setting('app.stock_ref_tipo', true), ''),
      NULLIF(current_setting('app.stock_ref_id', true), '')::BIGINT,
      NULLIF(current_setting('app.stock_user_id', true), '')::UUID,
      NEW.sucursal_id
    );$ancla$,
$nuevo$DECLARE
  v_origen  text;
  v_usuario uuid;
BEGIN
  IF OLD.stock IS DISTINCT FROM NEW.stock THEN
    v_origen  := NULLIF(current_setting('app.stock_origen', true), '');
    v_usuario := NULLIF(current_setting('app.stock_user_id', true), '')::UUID;

    -- #1043: un UPDATE de stock por PostgREST (la ficha del producto) no puede
    -- setear app.stock_origen. Se lo reconoce como productos_proteger_columnas:
    -- corre como 'authenticated' y es el UPDATE directo, no un trigger anidado.
    -- Ninguna función INVOKER escribe stock, así que una RPC sin etiqueta corre
    -- como su dueño y sigue cayendo en 'auto', que es lo que mira STK-D.
    IF v_origen IS NULL AND current_user = 'authenticated' AND pg_trigger_depth() = 1 THEN
      v_origen  := 'ajuste_manual';
      v_usuario := COALESCE(v_usuario, auth.uid());
    END IF;

    INSERT INTO stock_historico (
      producto_id, stock_anterior, stock_nuevo, origen,
      referencia_tipo, referencia_id, usuario_id, sucursal_id
    ) VALUES (
      NEW.id, OLD.stock, NEW.stock,
      COALESCE(v_origen, 'auto'),
      NULLIF(current_setting('app.stock_ref_tipo', true), ''),
      NULLIF(current_setting('app.stock_ref_id', true), '')::BIGINT,
      v_usuario,
      NEW.sucursal_id
    );$nuevo$);

-- ---------------------------------------------------------------------------
-- 4 · registrar_nota_credito: la devolución dice de dónde viene.
-- ---------------------------------------------------------------------------
SELECT public._mig1043_ancla('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)'::regprocedure,
$ancla$  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP$ancla$,
$nuevo$  -- #1043: la devolución baja stock etiquetada para el ledger; la referencia es
  -- la nota, como en registrar_nota_credito_lote. Antes entraba como 'auto'.
  PERFORM set_config('app.stock_origen',   'nota_credito',   true);
  PERFORM set_config('app.stock_ref_tipo', 'notas_credito',  true);
  PERFORM set_config('app.stock_ref_id',   v_nota_id::text,  true);
  PERFORM set_config('app.stock_user_id',  auth.uid()::text, true);

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP$nuevo$);

-- ---------------------------------------------------------------------------
-- 5 · ajustar_stock_promocion_completo: el ajuste dice de dónde viene.
-- ---------------------------------------------------------------------------
SELECT public._mig1043_ancla('public.ajustar_stock_promocion_completo(bigint,bigint,integer,integer,uuid,text)'::regprocedure,
$ancla$  UPDATE productos SET stock = v_stock_nuevo, updated_at = NOW()
  WHERE id = p_producto_id AND sucursal_id = v_sucursal;$ancla$,
$nuevo$  -- #1043: etiquetado para el ledger; la referencia es la merma que lo explica.
  PERFORM set_config('app.stock_origen',   'ajuste_promo',      true);
  PERFORM set_config('app.stock_ref_tipo', 'mermas_stock',      true);
  PERFORM set_config('app.stock_ref_id',   v_merma_id::text,    true);
  PERFORM set_config('app.stock_user_id',  p_usuario_id::text,  true);

  UPDATE productos SET stock = v_stock_nuevo, updated_at = NOW()
  WHERE id = p_producto_id AND sucursal_id = v_sucursal;$nuevo$);

-- ---------------------------------------------------------------------------
-- 6 · auditoria_integridad(): los siete checks.
--     Ningún id nuevo: se reescriben los existentes, por ancla.
-- ---------------------------------------------------------------------------
SELECT public._mig1043_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$    ('VENTA-I','low','pedido cancelado debe tener total, total_neto, total_iva y total_real en 0 (4 legacy de abril, ver mig 235)',$ancla$,
$nuevo$    -- #1043: los 4 cancelados de abril que la 235 había dejado se pusieron en 0.
    ('VENTA-I','low','pedido cancelado debe tener total, total_neto, total_iva y total_real en 0',$nuevo$);

SELECT public._mig1043_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$    ('VENTA-J','low','ningún pedido entregado sin items (id 652 legacy)',
      (SELECT count(*) FROM pedidos p WHERE estado='entregado' AND NOT EXISTS (SELECT 1 FROM pedido_items pi WHERE pi.pedido_id=p.id))),$ancla$,
$nuevo$    -- #1043: el canje (canal 'cambio') nace sin ítems por diseño: lo canjeado
    -- vive en recorrido_cambios, y eso lo cuida CAMBIO-03. El 652 es legacy: el
    -- 2026-05-05 un admin le borró su único ítem y lo marcó entregado en el
    -- mismo segundo.
    ('VENTA-J','low','ninguna venta entregada sin items',
      (SELECT count(*) FROM pedidos p WHERE estado='entregado' AND canal<>'cambio' AND p.id<>652
         AND NOT EXISTS (SELECT 1 FROM pedido_items pi WHERE pi.pedido_id=p.id))),$nuevo$);

SELECT public._mig1043_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$    ('COSTO-B','medium','productos con ventas entregadas y costo NULL/0 (inflan margen)',
      (SELECT count(DISTINCT prod.id) FROM pedido_items pi JOIN pedidos p ON p.id=pi.pedido_id JOIN productos prod ON prod.id=pi.producto_id
        WHERE p.estado='entregado' AND p.canal<>'cambio' AND COALESCE(p.tipo_factura,'ZZ')<>'VB' AND NOT pi.es_bonificacion AND (prod.costo_sin_iva IS NULL OR prod.costo_sin_iva=0))),$ancla$,
$nuevo$    -- #1043: "sin costo" es costo_valuacion(...) IS NULL con el snapshot de la
    -- línea, lo mismo que deciden los reportes (238, #511); costo_sin_iva
    -- suelto no lo es. La línea 2401 (pedido 895, producto 186, suc. 2) es
    -- legacy: una venta del 2026-03-21 de un producto que nunca se compró;
    -- decisión del dueño (2026-10-09): se excluye la línea, no el producto.
    ('COSTO-B','medium','productos con ventas entregadas valuadas sin costo (inflan margen)',
      (SELECT count(DISTINCT prod.id) FROM pedido_items pi JOIN pedidos p ON p.id=pi.pedido_id JOIN productos prod ON prod.id=pi.producto_id
        WHERE p.estado='entregado' AND p.canal<>'cambio' AND COALESCE(p.tipo_factura,'ZZ')<>'VB' AND NOT pi.es_bonificacion AND pi.id<>2401
          AND public.costo_valuacion(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
                                     prod.costo_sin_iva, prod.impuestos_internos) IS NULL)),$nuevo$);

SELECT public._mig1043_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$    ('MERMA-I','medium','mermas reales sin usuario_id (trazabilidad pendiente P1)',$ancla$,
$nuevo$    -- #1043: las 96 de abril a septiembre se completaron desde audit_logs.
    ('MERMA-I','medium','mermas reales sin usuario_id',$nuevo$);

SELECT public._mig1043_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$    ('COMPRA-A2','medium','compras.subtotal = SUM(compra_items.subtotal) (5 legacy)',
      (SELECT count(*) FROM compras c JOIN (SELECT compra_id, sum(subtotal) s FROM compra_items GROUP BY compra_id) it ON it.compra_id=c.id
        WHERE c.estado<>'cancelada' AND abs(COALESCE(c.subtotal,0)-it.s)>1.0)),$ancla$,
$nuevo$    -- #1043: las compras 5, 6, 19, 39 y 40 (ene-mar 2026) son legacy de carga
    -- incompleta: la 40 tiene la cabecera en el doble de sus renglones y la 39
    -- cuenta uno dos veces. Arreglarlas pide la factura física; se excluyen para
    -- que una compra NUEVA desfasada se note.
    ('COMPRA-A2','medium','compras.subtotal = SUM(compra_items.subtotal)',
      (SELECT count(*) FROM compras c JOIN (SELECT compra_id, sum(subtotal) s FROM compra_items GROUP BY compra_id) it ON it.compra_id=c.id
        WHERE c.estado<>'cancelada' AND c.id NOT IN (5,6,19,39,40) AND abs(COALESCE(c.subtotal,0)-it.s)>1.0)),$nuevo$);

SELECT public._mig1043_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$    ('COMIS-01','medium','venta entregada sin vendedor (usuario_id en perfiles)',
      (SELECT count(*) FROM pedidos WHERE estado='entregado' AND canal<>'cambio' AND (usuario_id IS NULL OR usuario_id NOT IN (SELECT id FROM perfiles)))),$ancla$,
$nuevo$    -- #1043: el 872 y el 904 (suc. 2, 2026-03-25) vienen de la importación de
    -- Taco Pozo (062) y su vendedor no tuvo match. Decisión del dueño
    -- (2026-10-09): quedan sin vendedor y se excluyen.
    ('COMIS-01','medium','venta entregada sin vendedor (usuario_id en perfiles)',
      (SELECT count(*) FROM pedidos WHERE estado='entregado' AND canal<>'cambio' AND id NOT IN (872,904) AND (usuario_id IS NULL OR usuario_id NOT IN (SELECT id FROM perfiles)))),$nuevo$);

-- STK-D: el corte es el último 'auto' sin referencia que existe al aplicar,
-- después de cerrar los caminos de las secciones 3 a 5.
DO $stkd$
DECLARE
  v_corte bigint;
BEGIN
  SELECT max(id) INTO v_corte FROM stock_historico WHERE origen = 'auto' AND referencia_id IS NULL;
  RAISE NOTICE '#1043 · STK-D corta en stock_historico.id %', v_corte;
  PERFORM public._mig1043_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$    ('STK-D','info','movimientos origen=auto sin referencia (trazabilidad pendiente P1)',
      (SELECT count(*) FROM stock_historico WHERE origen='auto' AND referencia_id IS NULL)),$ancla$,
    format(
$nuevo$    -- #1043: hasta la fila %1$s son legacy, de caminos que las migs 229, 232,
    -- 240, 245 y la de #1043 etiquetaron (la ficha de producto por REST quedó
    -- como 'ajuste_manual'). Un 'auto' sin referencia nuevo es un camino que
    -- mueve stock sin declarar app.stock_origen.
    ('STK-D','info','movimientos origen=auto sin referencia (un camino que mueve stock sin declarar el origen)',
      (SELECT count(*) FROM stock_historico WHERE origen='auto' AND referencia_id IS NULL AND id > %1$s)),$nuevo$,
      v_corte));
END
$stkd$;

DROP FUNCTION public._mig1043_ancla(regprocedure, text, text);

-- ---------------------------------------------------------------------------
-- 7 · Verificación: en cero, sin ids repetidos, y mordiendo.
--     Cada canario se deshace solo con un SQLSTATE centinela.
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_lista text;
  v_n     int;
  v_admin uuid;
  v_suc   bigint;
  v_prod  bigint;
  r       record;
BEGIN
  -- 7.1 · Los siete, una vez cada uno y en cero.
  SELECT string_agg(format('%s=%s', c->>'id', c->>'violaciones'), ', ') INTO v_lista
    FROM jsonb_array_elements(public.auditoria_integridad() -> 'checks') c
   WHERE c->>'id' IN ('MERMA-I','COMPRA-A2','COMIS-01','COSTO-B','VENTA-I','VENTA-J','STK-D')
     AND (c->>'violaciones')::int <> 0;
  IF v_lista IS NOT NULL THEN
    RAISE EXCEPTION '#1043 · checks fuera de cero: %', v_lista;
  END IF;

  SELECT string_agg(id, ', ') INTO v_lista FROM (
    SELECT c->>'id' AS id FROM jsonb_array_elements(public.auditoria_integridad() -> 'checks') c
     GROUP BY 1 HAVING count(*) > 1) d;
  IF v_lista IS NOT NULL THEN
    RAISE EXCEPTION '#1043 · ids repetidos en auditoria_integridad(): %', v_lista;
  END IF;

  SELECT count(*) INTO v_n FROM jsonb_array_elements(public.auditoria_integridad() -> 'checks') c
   WHERE c->>'id' IN ('MERMA-I','COMPRA-A2','COMIS-01','COSTO-B','VENTA-I','VENTA-J','STK-D');
  IF v_n <> 7 THEN
    RAISE EXCEPTION '#1043 · faltan checks: aparecen % de 7', v_n;
  END IF;

  -- 7.2 · Las únicas funciones que escriben stock sin declarar el origen son
  --       las dos que quedan a sabiendas.
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY 1) INTO v_lista
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
     AND pg_get_functiondef(p.oid) ~* 'UPDATE\s+(public\.)?productos\M'
     AND pg_get_functiondef(p.oid) ~* 'stock\s*='
     AND pg_get_functiondef(p.oid) !~ 'app\.stock_origen'
     AND p.proname NOT IN ('descontar_stock_atomico', 'registrar_transferencia');
  IF v_lista IS NOT NULL THEN
    RAISE EXCEPTION '#1043 · funciones que escriben stock sin app.stock_origen: %', v_lista;
  END IF;

  -- 7.3 · La ficha (UPDATE por REST) queda como 'ajuste_manual' de quien la hizo.
  SELECT pf.id, us.sucursal_id INTO v_admin, v_suc
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true)
   ORDER BY us.sucursal_id, pf.id LIMIT 1;
  SELECT id INTO v_prod FROM productos WHERE sucursal_id = v_suc AND activo AND stock > 0 ORDER BY id LIMIT 1;

  BEGIN
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE productos SET stock = stock + 1 WHERE id = v_prod AND sucursal_id = v_suc;
    EXECUTE 'RESET ROLE';
    SELECT * INTO r FROM stock_historico WHERE producto_id = v_prod ORDER BY id DESC LIMIT 1;
    IF r.origen IS DISTINCT FROM 'ajuste_manual' OR r.usuario_id IS DISTINCT FROM v_admin THEN
      RAISE EXCEPTION '#1043 · la edición por REST quedó origen=%, usuario=%', r.origen, r.usuario_id;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
  END;

  -- 7.4 · Un movimiento de servidor sin origen sí se ve en STK-D.
  BEGIN
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE productos SET stock = stock + 1 WHERE id = v_prod;
    SELECT (c->>'violaciones')::int INTO v_n
      FROM jsonb_array_elements(public.auditoria_integridad() -> 'checks') c WHERE c->>'id' = 'STK-D';
    IF v_n <> 1 THEN
      RAISE EXCEPTION '#1043 · STK-D no ve un movimiento nuevo sin origen (%)', v_n;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
  END;
END
$verif$;

COMMIT;

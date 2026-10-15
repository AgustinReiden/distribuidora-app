-- ===========================================================================
-- ARREGLO DE DATO — #1167: salvedades que una edicion del pedido ya deshizo
-- ===========================================================================
--
--   ESTADO: YA EJECUTADO en prod el 2026-10-14, en modo 'si',
--   despues del ensayo en modo 'no'. Resultado: 56, 57, 132 y 271 en
--   'anulada' con su fila 'anulacion' en salvedad_historial; 44, 133 y 264
--   siguen pendientes; auditoria_integridad() overall_ok = true (SALV-A,
--   STK-D, STK-F, VENTA-J en 0). El archivo queda con v_modo := 'no': volver
--   a correrlo aborta sin tocar nada (la guarda devuelve 'no_pendiente').
--
-- Vive en `scripts/` y no en `migrations/` porque es un arreglo puntual de
-- dato (precedente: scripts/fix-pedido-3602-pagos-duplicados.sql): una
-- migracion dejaria un UPDATE de 4 filas corriendo en cada entorno nuevo.
--
-- QUE PASO
-- Las salvedades 56 y 57 (pedido 910, suc. 2), 132 (pedido 3408, suc. 1) y
-- 271 (pedido 5599, suc. 1) se registraron con el pedido entregado. Despues,
-- el MISMO usuario que las cargo reabrio el pedido (entregado -> asignado) y
-- edito los items: la edicion volvio a poner las unidades, el total y el cobro
-- como si la salvedad no existiera.
--
--   salvedad | pedido   | edicion que la deshizo (pedido_historial)
--   ---------+----------+---------------------------------------------------
--   56 / 57  | 910 s2   | #7634, 9 min despues, encargado c6c04890
--   132      | 3408 s1  | #18926, 3 min 46 s despues, admin d1614e4f
--   271      | 5599 s1  | #30909, 53 s despues, admin a711e871
--
-- Lo unico que quedo mal es la fila de la salvedad: sigue `pendiente`.
--
-- POR QUE NO SE ANULAN CON anular_salvedad
-- anular_salvedad las rechaza con codigo 'pedido_editado', y esta bien que lo
-- haga: anular reinsertaria la linea (o le sumaria la cantidad), inventaria
-- $20.650 de deuda (56/57 +$12.800, 132 +$850, 271 +$7.000 sobre pedidos ya
-- cobrados) y bajaria el stock otra vez. Y una "anulacion que solo deshace la
-- merma y el stock" tambien esta mal: la edicion ya retomo esas unidades, asi
-- que duplicaria la baja de 202 s2 (-3), 205 s2 (-10) y 170 s1 (-1); en la
-- 271 (stock_devuelto = false) no haria nada.
--
-- QUE HACE
-- Pasa las 4 a `anulada` con una fila 'anulacion' en salvedad_historial. La
-- nota dice que edicion la supero, quien la hizo y cuando.
--
-- QUE NO HACE
-- No toca stock, total, pagos, lineas, lotes ni mermas (ninguna de las 4 tiene
-- merma ni lotes_devueltos). No setea GUCs de stock porque no toca productos:
-- STK-D y STK-F no se enteran.
--
-- `resuelto_por` y `salvedad_historial.usuario_id` quedan NULL A PROPOSITO:
-- nadie de la app hizo esta anulacion, y la UI oculta el "Por:" cuando no hay
-- nombre. Quien edito y cuando queda escrito en la nota.
--
-- Lo que cambia ademas: 910 y 5599 dejan de figurar como
-- `entregado_con_salvedad` en las jornadas de preventista y de transportista
-- (y en sus detalles), y quedan habilitados para cambiar_tipo_factura_pedido y
-- la rama VB de cancelar_pedido_con_stock (leen `estado_resolucion <>
-- 'anulada'`). 3408 sigue con la 133, que es una salvedad real.
--
-- QUE QUEDA AFUERA
-- - 44 (pedido 1142) y 264 (pedido 5504): son sobre un regalo viejo (precio 0,
--   es_bonificacion NULL). El dueño confirmo (2026-10-14) que el cliente NO
--   recibio el regalo: la salvedad es verdad, queda pendiente y se resuelve
--   desde la app (ModalResolverSalvedad). La guarda las rechaza por 'regalo'.
-- - La deriva de stock de 162 s1 (-1, por la 271, que no devolvio y la edicion
--   volvio a bajar) y 86 s1 (+1, por la 44, que devolvio un regalo que nunca
--   bajo) no se ajusta: queda para el proximo conteo fisico, cargado desde la
--   ficha (decision del dueño, 2026-10-14).
--
-- ES UN ENSAYO DE UNA SOLA VEZ, NO UNA PRUEBA DE REGRESION
-- Mide datos reales de prod. Una vez aplicado, la guarda devuelve
-- 'no_pendiente' para las 4 y el ensayo ya no se puede repetir (aborta sin
-- tocar nada). La salida del ensayo y de la prueba de mordida van en el PR.
--
-- ATOMICIDAD
-- Todo lo que escribe y verifica va en un solo `DO $fix1167$`, que es una sola
-- sentencia: su RAISE EXCEPTION final revierte todo lo que hizo, se corra con
-- `psql -f` con o sin `-1`, con o sin BEGIN, o pegado en execute_sql. Los modos
-- son constantes dentro del DO. Afuera solo quedan dos funciones de pg_temp
-- (la guarda y la foto), que viven en el esquema temporal de la sesion y
-- mueren con ella. El BEGIN/COMMIT del archivo es un cinturon: en modo
-- ensayo el COMMIT se vuelve ROLLBACK.
--
-- COMO SE USA
-- 1. Ensayo (por defecto, v_modo := 'no'): termina SIEMPRE en
--      ENSAYO OK (#1167: ...) — revertido      -> se puede aplicar
--      ENSAYO FALLO (N fallas) ...             -> no aplicar, mirar la lista
--      FIX 1167 ABORTADO: ...                  -> la guarda rechazo algun id
--      psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f scripts/fix-salvedades-superadas-1167.sql
-- 2. Aplicar (solo con el OK del dueño): cambiar DOS constantes del DO,
--      v_modo     := 'si';
--      v_confirmo := '56,57,132,271';   -- tiene que ser igual a v_ids
--    y correr el mismo comando. Termina con NOTICE 'FIX 1167 APLICADO'.
--    Si alguien edito o resolvio una de las 4 entre el ensayo y la aplicacion,
--    la guarda aborta todo: volver a correr el ensayo.
-- 3. Caso futuro igual: agregar el id a v_ids y a v_confirmo. La guarda decide
--    si es una salvedad superada; si no lo es, aborta.
-- ===========================================================================

BEGIN;

-- La guarda: NULL si la salvedad esta superada por una edicion posterior y se
-- puede cerrar sin mover nada; si no, el motivo del rechazo.
CREATE OR REPLACE FUNCTION pg_temp.salvedad_superada_1167(p_id bigint)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE s public.salvedades_items; p public.pedidos; v_cant numeric;
BEGIN
  SELECT * INTO s FROM public.salvedades_items WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'no_existe'; END IF;
  IF s.estado_resolucion <> 'pendiente' THEN RETURN 'no_pendiente'; END IF;
  IF s.lotes_devueltos IS NOT NULL THEN RETURN 'con_lotes_devueltos'; END IF;
  IF COALESCE(s.es_bonificacion, false)
     OR (s.es_bonificacion IS NULL AND s.precio_unitario <= 0) THEN RETURN 'regalo'; END IF;
  IF EXISTS (SELECT 1 FROM public.mermas_stock m WHERE m.salvedad_id = s.id
               AND m.sucursal_id = s.sucursal_id AND m.anulada_at IS NULL) THEN RETURN 'con_merma'; END IF;
  SELECT * INTO p FROM public.pedidos WHERE id = s.pedido_id AND sucursal_id = s.sucursal_id FOR UPDATE;
  IF p.estado IN ('cancelado','anulado') THEN RETURN 'pedido_cancelado'; END IF;
  IF public.nota_credito_vigente_de_pedido(p.id) IS NOT NULL THEN RETURN 'nota_credito_vigente'; END IF;
  -- mismo predicado que el rechazo 'pedido_editado' de anular_salvedad
  IF NOT EXISTS (SELECT 1 FROM public.pedido_historial h WHERE h.pedido_id = s.pedido_id
                   AND h.sucursal_id = s.sucursal_id AND h.campo_modificado = 'items'
                   AND h.created_at > s.created_at) THEN RETURN 'sin_edicion_posterior'; END IF;
  -- la edicion tiene que haber devuelto al pedido todo lo que la salvedad saco
  SELECT COALESCE(sum(cantidad), 0) INTO v_cant FROM public.pedido_items
   WHERE pedido_id = s.pedido_id AND sucursal_id = s.sucursal_id
     AND producto_id = s.producto_id AND NOT COALESCE(es_bonificacion, false);
  IF v_cant < s.cantidad_original THEN RETURN 'pedido_no_cubre'; END IF;
  IF abs(p.total - COALESCE(p.monto_pagado, 0)) > 0.01 THEN RETURN 'cobro_descuadrado'; END IF;
  RETURN NULL;
END $f$;

-- La foto de lo que NO tiene que cambiar: plata y lineas de los pedidos de las
-- salvedades, y stock, ledger, lotes y mermas de sus (producto, sucursal).
CREATE OR REPLACE FUNCTION pg_temp.foto_1167(p_ids bigint[])
RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object(
    'pedidos', (
      SELECT jsonb_object_agg(pe.id || '/' || pe.sucursal_id, jsonb_build_object(
               'estado', pe.estado, 'estado_pago', pe.estado_pago,
               'total', pe.total, 'monto_pagado', pe.monto_pagado,
               'pagos', (SELECT COALESCE(sum(pg.monto), 0) FROM public.pagos pg
                          WHERE pg.pedido_id = pe.id AND pg.sucursal_id = pe.sucursal_id),
               'lineas', (SELECT COALESCE(jsonb_agg(jsonb_build_array(pi.id, pi.producto_id, pi.cantidad,
                                                    pi.precio_unitario, pi.es_bonificacion) ORDER BY pi.id), '[]')
                            FROM public.pedido_items pi
                           WHERE pi.pedido_id = pe.id AND pi.sucursal_id = pe.sucursal_id),
               'huella', (SELECT count(*) FROM public.pedido_item_lotes pil
                            JOIN public.pedido_items pi ON pi.id = pil.pedido_item_id
                           WHERE pi.pedido_id = pe.id AND pi.sucursal_id = pe.sucursal_id),
               'mermas', (SELECT count(*) FROM public.mermas_stock m
                            JOIN public.salvedades_items s2 ON s2.id = m.salvedad_id
                           WHERE s2.pedido_id = pe.id AND s2.sucursal_id = pe.sucursal_id)))
        FROM public.pedidos pe
       WHERE (pe.id, pe.sucursal_id) IN (SELECT pedido_id, sucursal_id FROM public.salvedades_items
                                          WHERE id = ANY (p_ids))),
    'productos', (
      SELECT jsonb_object_agg(pr.id || '/' || pr.sucursal_id, jsonb_build_object(
               'stock', pr.stock,
               'ledger', (SELECT count(*) FROM public.stock_historico h
                           WHERE h.producto_id = pr.id AND h.sucursal_id = pr.sucursal_id),
               'lotes', (SELECT COALESCE(sum(l.cantidad_restante), 0) FROM public.producto_lotes l
                          WHERE l.producto_id = pr.id AND l.sucursal_id = pr.sucursal_id),
               'mermas', (SELECT count(*) FROM public.mermas_stock m
                           WHERE m.producto_id = pr.id AND m.sucursal_id = pr.sucursal_id),
               'mermas_vivas', (SELECT count(*) FROM public.mermas_stock m
                                 WHERE m.producto_id = pr.id AND m.sucursal_id = pr.sucursal_id
                                   AND m.anulada_at IS NULL)))
        FROM public.productos pr
       WHERE (pr.id, pr.sucursal_id) IN (SELECT producto_id, sucursal_id FROM public.salvedades_items
                                          WHERE id = ANY (p_ids))),
    -- SALV-A, la misma consulta de auditoria_integridad()
    'salv_a', (SELECT count(*) FROM public.mermas_stock m
                 JOIN public.salvedades_items s ON s.id = m.salvedad_id AND s.sucursal_id = m.sucursal_id
                WHERE s.estado_resolucion = 'anulada' AND m.anulada_at IS NULL))
$f$;

DO $fix1167$
DECLARE
  -- ---- constantes: las unicas dos que se cambian para aplicar ------------
  v_modo     text     := 'no';                 -- 'si' solo con OK del dueño
  v_confirmo text     := '';                   -- en modo 'si': '56,57,132,271'
  v_ids      bigint[] := ARRAY[56,57,132,271];
  -- ------------------------------------------------------------------------
  -- testigos: salvedades que la guarda tiene que seguir rechazando
  v_testigos bigint[] := ARRAY[44,264,133];

  v_antes        jsonb;
  v_despues      jsonb;
  v_hist_antes   bigint;
  v_hist_test    bigint;
  v_elegidas     bigint[];
  v_rechazos     text[] := '{}';
  v_fallas       text[] := '{}';
  v_id           bigint;
  v_r            text;
  v_n            bigint;
  v_nota         text;
  s              public.salvedades_items;
  h              record;
BEGIN
  -- 1. Modo
  IF v_modo NOT IN ('no', 'si') THEN
    RAISE EXCEPTION 'FIX 1167: v_modo tiene que ser ''no'' o ''si'' (es %)', v_modo;
  END IF;
  IF v_modo = 'si' AND v_confirmo IS DISTINCT FROM array_to_string(v_ids, ',') THEN
    RAISE EXCEPTION 'FIX 1167: confirmacion no coincide con v_ids (v_confirmo=%, v_ids=%)',
      v_confirmo, array_to_string(v_ids, ',');
  END IF;

  -- 2. Foto "antes"
  v_antes := pg_temp.foto_1167(v_ids);
  SELECT count(*) INTO v_hist_antes FROM public.salvedad_historial WHERE salvedad_id = ANY (v_ids);
  SELECT count(*) INTO v_hist_test  FROM public.salvedad_historial WHERE salvedad_id = ANY (v_testigos);

  -- 3. Primera pasada: todo o nada
  FOREACH v_id IN ARRAY v_ids LOOP
    v_r := pg_temp.salvedad_superada_1167(v_id);
    IF v_r IS NOT NULL THEN
      v_rechazos := v_rechazos || (v_id || ': ' || v_r);
    END IF;
  END LOOP;
  IF cardinality(v_rechazos) > 0 THEN
    RAISE EXCEPTION 'FIX 1167 ABORTADO: la guarda rechaza %', array_to_string(v_rechazos, ', ');
  END IF;

  -- El conjunto de pendientes que la guarda elige hoy tiene que ser v_ids
  SELECT array_agg(id ORDER BY id) INTO v_elegidas
    FROM public.salvedades_items
   WHERE estado_resolucion = 'pendiente' AND pg_temp.salvedad_superada_1167(id) IS NULL;
  IF v_elegidas IS DISTINCT FROM (SELECT array_agg(x ORDER BY x) FROM unnest(v_ids) x) THEN
    RAISE EXCEPTION 'FIX 1167 ABORTADO: la guarda elige % entre las pendientes y v_ids es %',
      COALESCE(array_to_string(v_elegidas, ','), '(ninguna)'), array_to_string(v_ids, ',');
  END IF;

  -- 4. Segunda pasada: cerrar cada una
  FOREACH v_id IN ARRAY v_ids LOOP
    SELECT * INTO s FROM public.salvedades_items WHERE id = v_id;
    SELECT ph.id, ph.usuario_id, ph.created_at INTO h
      FROM public.pedido_historial ph
     WHERE ph.pedido_id = s.pedido_id AND ph.sucursal_id = s.sucursal_id
       AND ph.campo_modificado = 'items' AND ph.created_at > s.created_at
     ORDER BY ph.created_at, ph.id
     LIMIT 1;
    v_nota := format('Superada por la edición del pedido (pedido_historial #%s, usuario %s, %s): '
                     'la edición ya restituyó unidades, total y cobro. Cerrada a mano por #1167 el %s, '
                     'sin mover stock ni plata.',
                     h.id, h.usuario_id,
                     to_char(h.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires', 'YYYY-MM-DD HH24:MI'),
                     to_char(now() AT TIME ZONE 'America/Argentina/Buenos_Aires', 'YYYY-MM-DD'));
    UPDATE public.salvedades_items
       SET estado_resolucion = 'anulada',
           resolucion_notas  = v_nota,
           resolucion_fecha  = now(),
           resuelto_por      = NULL,
           updated_at        = now()
     WHERE id = v_id AND sucursal_id = s.sucursal_id;
    INSERT INTO public.salvedad_historial
      (salvedad_id, accion, estado_anterior, estado_nuevo, notas, usuario_id, sucursal_id)
    VALUES (v_id, 'anulacion', 'pendiente', 'anulada', v_nota, NULL, s.sucursal_id);
  END LOOP;

  -- 5. Verificacion
  -- [F] las 4 quedan anuladas, sin autor, con fecha y la nota de #1167
  SELECT count(*) INTO v_n FROM public.salvedades_items
   WHERE id = ANY (v_ids) AND estado_resolucion = 'anulada' AND resuelto_por IS NULL
     AND resolucion_fecha IS NOT NULL AND resolucion_notas LIKE '%#1167%';
  IF v_n <> cardinality(v_ids) THEN
    v_fallas := v_fallas || format('[F] anuladas con nota #1167: %s de %s', v_n, cardinality(v_ids));
  END IF;

  -- [F] exactamente una fila nueva 'anulacion' sin usuario por salvedad
  SELECT count(*) INTO v_n FROM public.salvedad_historial WHERE salvedad_id = ANY (v_ids);
  IF v_n - v_hist_antes <> cardinality(v_ids) THEN
    v_fallas := v_fallas || format('[F] filas nuevas de historial: %s (esperaba %s)',
                                   v_n - v_hist_antes, cardinality(v_ids));
  END IF;
  SELECT count(DISTINCT salvedad_id) INTO v_n FROM public.salvedad_historial
   WHERE salvedad_id = ANY (v_ids) AND accion = 'anulacion' AND usuario_id IS NULL
     AND estado_anterior = 'pendiente' AND estado_nuevo = 'anulada';
  IF v_n <> cardinality(v_ids) THEN
    v_fallas := v_fallas || format('[F] salvedades con su fila anulacion sin usuario: %s de %s',
                                   v_n, cardinality(v_ids));
  END IF;

  -- [F] 910 y 5599 quedan sin salvedad viva: es el predicado
  -- `estado_resolucion <> 'anulada'` que leen las jornadas y
  -- cambiar_tipo_factura_pedido. (3408 sigue con la 133.)
  SELECT count(*) INTO v_n FROM public.salvedades_items
   WHERE ((pedido_id = 910 AND sucursal_id = 2) OR (pedido_id = 5599 AND sucursal_id = 1))
     AND estado_resolucion <> 'anulada';
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format('[F] salvedades no anuladas en 910/5599: %s (esperaba 0)', v_n);
  END IF;

  -- [R] plata, lineas, stock, ledger, lotes y mermas identicos
  v_despues := pg_temp.foto_1167(v_ids);
  IF v_despues IS DISTINCT FROM v_antes THEN
    v_fallas := v_fallas || format('[R] la foto cambio: antes %s / despues %s', v_antes, v_despues);
  END IF;

  -- [R] SALV-A sigue en 0
  IF (v_despues->>'salv_a')::bigint <> 0 THEN
    v_fallas := v_fallas || format('[R] SALV-A = %s', v_despues->>'salv_a');
  END IF;

  -- [R] la guarda sigue rechazando a los testigos y a las ya cerradas
  v_r := pg_temp.salvedad_superada_1167(44);
  IF v_r IS DISTINCT FROM 'regalo' THEN
    v_fallas := v_fallas || format('[R] guarda(44) = %s (esperaba regalo)', COALESCE(v_r, 'NULL'));
  END IF;
  v_r := pg_temp.salvedad_superada_1167(264);
  IF v_r IS DISTINCT FROM 'regalo' THEN
    v_fallas := v_fallas || format('[R] guarda(264) = %s (esperaba regalo)', COALESCE(v_r, 'NULL'));
  END IF;
  v_r := pg_temp.salvedad_superada_1167(133);
  IF v_r IS DISTINCT FROM 'sin_edicion_posterior' THEN
    v_fallas := v_fallas || format('[R] guarda(133) = %s (esperaba sin_edicion_posterior)', COALESCE(v_r, 'NULL'));
  END IF;
  v_r := pg_temp.salvedad_superada_1167(56);
  IF v_r IS DISTINCT FROM 'no_pendiente' THEN
    v_fallas := v_fallas || format('[R] guarda(56) = %s (esperaba no_pendiente)', COALESCE(v_r, 'NULL'));
  END IF;
  SELECT count(*) INTO v_n FROM public.salvedades_items
   WHERE id = ANY (v_testigos) AND estado_resolucion = 'pendiente';
  IF v_n <> cardinality(v_testigos) THEN
    v_fallas := v_fallas || format('[R] testigos 44/264/133 pendientes: %s de %s', v_n, cardinality(v_testigos));
  END IF;
  SELECT count(*) INTO v_n FROM public.salvedad_historial WHERE salvedad_id = ANY (v_testigos);
  IF v_n <> v_hist_test THEN
    v_fallas := v_fallas || format('[R] historial de los testigos: %s -> %s', v_hist_test, v_n);
  END IF;

  -- [R] tras cerrar, la guarda no elige ninguna pendiente
  SELECT array_agg(id ORDER BY id) INTO v_elegidas
    FROM public.salvedades_items
   WHERE estado_resolucion = 'pendiente' AND pg_temp.salvedad_superada_1167(id) IS NULL;
  IF v_elegidas IS NOT NULL THEN
    v_fallas := v_fallas || format('[R] la guarda todavia elige: %s', array_to_string(v_elegidas, ','));
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas)\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;

  -- 6. Cierre
  IF v_modo <> 'si' THEN
    RAISE EXCEPTION 'ENSAYO OK (#1167: % salvedades superadas cerradas sin mover stock ni plata) — revertido',
      cardinality(v_ids);
  END IF;
  RAISE NOTICE 'FIX 1167 APLICADO: salvedades % anuladas, sin mover stock ni plata', array_to_string(v_ids, ',');
END
$fix1167$;

COMMIT;

-- ---------------------------------------------------------------------------
-- DESPUES DE APLICAR (solo lectura)
-- ---------------------------------------------------------------------------
-- select id, pedido_id, estado_resolucion, resuelto_por, resolucion_fecha, resolucion_notas
--   from salvedades_items where id in (44, 56, 57, 132, 133, 264, 271) order by id;
-- select salvedad_id, accion, estado_anterior, estado_nuevo, usuario_id, created_at
--   from salvedad_historial where salvedad_id in (56, 57, 132, 271) order by salvedad_id, id;
-- select auditoria_integridad()->'overall_ok' as overall_ok;
-- select x->>'id' as id, x->>'violaciones' as violaciones
--   from jsonb_array_elements(auditoria_integridad()->'checks') x
--  where x->>'id' in ('SALV-A','VENTA-J','STK-D','STK-F');

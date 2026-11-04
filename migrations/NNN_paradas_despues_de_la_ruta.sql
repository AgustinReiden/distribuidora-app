-- NNN · Las paradas se tocan después de la ruta, también al recalcular (#1406).
--
-- QUÉ PASABA
--   recalcular_recorrido realineaba las paradas (pasos a y b, UPDATE recorrido_pedidos ...
--   FROM pedidos) y recién después tomaba la ruta (la 441). aplicar_orden_ruta toma los
--   pedidos por id, después las rutas por id (439) y después escribe las paradas (el INSERT
--   ... ON CONFLICT DO UPDATE de recorrido_pedidos). Con una parada desfasada (un pedido
--   entregado cuya parada sigue pendiente, que es justo lo que recalcular viene a arreglar),
--   recalcular tenía la parada y pedía la ruta, y el reorden tenía la ruta y pedía la parada:
--   Postgres abortaba a uno con 40P01. No rompía datos, pero la parada seguía desfasada
--   (RUTA-A) hasta el próximo recálculo. El arnés de #1288 lo midió (C7k2): entre 27 y 63 de
--   200 rondas.
--
-- EL ORDEN
--   pedidos por id → recorridos por id → recorrido_pedidos. Es el de la 439, con las paradas
--   al final. Ya lo seguían aplicar_orden_ruta y las dos masivas: pedidos, rutas y el UPDATE de
--   pedidos que escribe la parada por el trigger (más el lock compartido de la rendición de la
--   443, antes de todo, que no cambia). Ahora lo siguen también:
--   · recalcular_recorrido: la ruta antes de (a) y (b). No bloquea los pedidos de la ruta:
--     quitar_pedido_de_recorridos_activos la llama con el pedido y sus rutas ya tomados (desde
--     cancelar_pedido_con_stock), y tomar pedidos después de una ruta rompería el mismo orden.
--   · actualizar_recorrido_entrega: las rutas del pedido antes de leer y escribir su parada.
--     Es lo que hacía falta para mover la de recalcular: la 441 la dejó al final porque la
--     entrega tomaba la parada antes que la ruta. Con la ruta primero sólo en recalcular, una
--     parada que dice entregado con el pedido sin entregar (el paso b) cruza a recalcular con la
--     entrega de ese pedido (C7j2).
--   · quitar_pedido_de_recorridos_activos: las rutas en curso del pedido antes de borrar sus
--     paradas. Desde la cancelación ya estaban tomadas; el front la llama sola, y borraba la
--     parada antes de tomar la ruta: con la entrega de este orden, la entrega de ese mismo
--     pedido se cruzaría con ella (C7l). No toma el pedido, que no escribe: con el pedido
--     antes de la ruta se cruzaría con cambiar_transportista_recorrido, que toma la ruta y
--     después sus pedidos.
--
-- QUÉ NO CAMBIA
--   Qué paradas se marcan, se realinean o se borran, qué rutas se recalculan y con qué cuenta,
--   las firmas y los EXECUTE. aplicar_orden_ruta y las masivas no se tocan. Cada lock de rutas
--   sigue en su propia sentencia y antes de contar (#1397).
--
-- Ensayo: scripts/test-paradas-ruta-1406.sql, y C7j2, C7k2 y C7l del arnés (scripts/concurrencia).
-- Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

DO $premisas$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.actualizar_recorrido_entrega()', 'e40474605f45251c7ce53e8632f248e8'),
      ('public.recalcular_recorrido(bigint)', 'b0daaa08ac1dbbd4a0565ed7acd66162'),
      ('public.quitar_pedido_de_recorridos_activos(bigint)', '31cee3b1339d8895fa474277c5d74c6e')
    ) AS t(firma, hash)
  LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure) <> r.hash THEN
      RAISE EXCEPTION '% cambió en prod (md5 %): rehacer el parche sobre el cuerpo vigente',
        r.firma, (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure);
    END IF;
  END LOOP;
END
$premisas$;

CREATE OR REPLACE FUNCTION public.actualizar_recorrido_entrega()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_parada       BIGINT;
  v_recorrido_id BIGINT;
  v_estado_rp    TEXT;
  v_rid          BIGINT;
BEGIN
  -- Las rutas del pedido se bloquean primero, todas juntas y por id, antes de
  -- leer y tocar su parada: el orden de la 439, el pedido (lo tiene el UPDATE
  -- que disparo el trigger), sus rutas, y recien despues las paradas. #1406:
  -- antes la parada se escribia primero; con recalcular_recorrido tomando la
  -- ruta antes que las paradas, una parada 'entregado' con el pedido sin
  -- entregar (su paso b) los cruzaba.
  --
  -- #1397: el lock va en su propia sentencia y ANTES de recalcular, como en
  -- recalcular_monto_pagado_pedido (#1247). Un UPDATE que espera la fila
  -- re-evalua el WHERE contra la version nueva, pero _recorrido_contadores ya
  -- corrio con la foto de su sentencia: si otra transaccion entregaba otro
  -- pedido de la misma ruta, el conteo no la veia y la pisaba. Despues de este
  -- PERFORM cada UPDATE de abajo arranca con una foto nueva.
  PERFORM 1
     FROM recorridos r
    WHERE r.id IN (SELECT rp.recorrido_id
                     FROM recorrido_pedidos rp
                    WHERE rp.pedido_id = NEW.id)
    ORDER BY r.id
      FOR NO KEY UPDATE;

  -- La parada del pedido (#1313): la viva (pendiente o entregada), de la ruta
  -- en curso primero y si no la mas reciente. Entre vivas sólo hay más de una
  -- con datos de antes de la mig 419. Sin filtro de fecha: el guard
  -- `r.fecha = CURRENT_DATE` de la mig 173 dejaba sin registrar el 79% de las
  -- entregas.
  SELECT rp.id, rp.recorrido_id, rp.estado_entrega
    INTO v_parada, v_recorrido_id, v_estado_rp
  FROM recorrido_pedidos rp
  JOIN recorridos r ON r.id = rp.recorrido_id
  WHERE rp.pedido_id = NEW.id
    AND rp.estado_entrega IN ('pendiente', 'entregado')
  ORDER BY (r.estado = 'en_curso') DESC, r.fecha DESC, r.created_at DESC, r.id DESC
  LIMIT 1;

  IF NEW.estado = 'entregado' AND OLD.estado IS DISTINCT FROM 'entregado' THEN
    -- Sin parada viva: el chofer lo marcó no entregado y igual se entregó sin
    -- re-rutearlo. Va a esa parada de la ruta en curso, y el intento queda en
    -- el historial.
    IF v_parada IS NULL THEN
      SELECT rp.id, rp.recorrido_id
        INTO v_parada, v_recorrido_id
      FROM recorrido_pedidos rp
      JOIN recorridos r ON r.id = rp.recorrido_id
      WHERE rp.pedido_id = NEW.id
        AND rp.estado_entrega = 'no_entregado'
        AND r.estado = 'en_curso'
      ORDER BY r.fecha DESC, r.created_at DESC, r.id DESC
      LIMIT 1;
      IF v_parada IS NOT NULL THEN
        PERFORM public._no_entregas_al_historial(ARRAY[v_parada]);
      END IF;
    END IF;

    -- Solo en la transicion a entregado: si no, un cobro posterior pisaria la
    -- hora_entrega real.
    IF v_parada IS NOT NULL THEN
      UPDATE recorrido_pedidos
      SET estado_entrega    = 'entregado',
          hora_entrega      = NOW(),
          motivo_no_entrega = NULL,
          nota_no_entrega   = NULL
      WHERE id = v_parada;
    END IF;

  ELSIF OLD.estado = 'entregado' AND NEW.estado IS DISTINCT FROM 'entregado'
        AND v_estado_rp = 'entregado' THEN
    -- Revertir la entrega: la parada vuelve a esperar (#1313). Antes quedaba
    -- 'entregado' hasta un recalcular_recorrido a mano.
    UPDATE recorrido_pedidos
    SET estado_entrega = 'pendiente',
        hora_entrega   = NULL
    WHERE id = v_parada;
  END IF;

  -- Los contadores se recalculan en TODAS las rutas que tienen al pedido (un
  -- cambio de total mueve lo facturado de la viva; en la historia no suma
  -- nada). Es recalculo, no delta, y sale de _recorrido_contadores. Las rutas
  -- ya quedaron bloqueadas por id al principio.
  FOR v_rid IN
    SELECT DISTINCT rp.recorrido_id
      FROM recorrido_pedidos rp
     WHERE rp.pedido_id = NEW.id
     ORDER BY rp.recorrido_id
  LOOP
    UPDATE recorridos r
    SET total_pedidos      = c.total_pedidos,
        pedidos_entregados = c.pedidos_entregados,
        total_cobrado      = c.total_cobrado,
        -- mig 234: una salvedad baja pedidos.total y el recorrido no se
        -- enteraba, asi que /recorridos mostraba "Pendiente" inflado.
        total_facturado    = c.total_facturado
    FROM public._recorrido_contadores(v_rid) c
    WHERE r.id = v_rid;
  END LOOP;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.recalcular_recorrido(p_recorrido_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_realineadas INT := 0;
  v_revertidas  INT := 0;
BEGIN
  -- Mismo criterio que auditoria_integridad (mig 105): auth.uid() NULL = contexto
  -- de migracion / service_role.
  IF auth.uid() IS NOT NULL AND NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado: recalcular_recorrido requiere encargado o admin'
      USING ERRCODE = '42501';
  END IF;

  -- #1406: la ruta se bloquea antes de tocar las paradas, en el orden de la 439
  -- (pedidos, rutas por id, paradas). La 441 la habia dejado despues de (a) y
  -- (b) porque la entrega tomaba la parada antes que la ruta; ahora la entrega
  -- toma la ruta primero. Con la parada primero se cruzaba con
  -- aplicar_orden_ruta, que tiene la ruta y escribe las paradas. No bloquea los
  -- pedidos: quitar_pedido_de_recorridos_activos la llama con el pedido y sus
  -- rutas ya tomados, y tomar pedidos despues de una ruta rompe el orden.
  -- #1397: en su propia sentencia y antes de contar. Si una entrega tenia la
  -- ruta tomada, el UPDATE de (c) esperaba con la foto de antes y pisaba su
  -- conteo.
  PERFORM 1 FROM recorridos WHERE id = p_recorrido_id FOR NO KEY UPDATE;

  -- a) el pedido esta entregado y la parada no se entero. La hora sale del
  --    historial (el insert real), no de now(). Sólo una parada pendiente: la
  --    de historia es de una ruta que no lo entregó (#1313).
  UPDATE recorrido_pedidos rp
     SET estado_entrega = 'entregado',
         hora_entrega   = COALESCE(
           rp.hora_entrega,
           (SELECT max(ph.created_at)
              FROM pedido_historial ph
             WHERE ph.pedido_id        = rp.pedido_id
               AND ph.campo_modificado = 'estado'
               AND ph.valor_nuevo LIKE 'entregado%'))
    FROM pedidos p
   WHERE p.id             = rp.pedido_id
     AND rp.recorrido_id  = p_recorrido_id
     AND p.estado         = 'entregado'
     AND rp.estado_entrega = 'pendiente';
  GET DIAGNOSTICS v_realineadas = ROW_COUNT;

  -- b) la parada dice entregado y el pedido ya no lo esta (entrega revertida).
  UPDATE recorrido_pedidos rp
     SET estado_entrega = 'pendiente',
         hora_entrega   = NULL
    FROM pedidos p
   WHERE p.id              = rp.pedido_id
     AND rp.recorrido_id   = p_recorrido_id
     AND rp.estado_entrega = 'entregado'
     AND p.estado         <> 'entregado';
  GET DIAGNOSTICS v_revertidas = ROW_COUNT;

  -- c) los cuatro contadores, desde las paradas (_recorrido_contadores).
  UPDATE recorridos r
     SET total_pedidos      = c.total_pedidos,
         total_facturado    = c.total_facturado,
         pedidos_entregados = c.pedidos_entregados,
         total_cobrado      = c.total_cobrado
    FROM public._recorrido_contadores(p_recorrido_id) c
   WHERE r.id = p_recorrido_id;

  RETURN jsonb_build_object(
    'success',             true,
    'recorrido_id',        p_recorrido_id,
    'paradas_realineadas', v_realineadas,
    'paradas_revertidas',  v_revertidas
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.quitar_pedido_de_recorridos_activos(p_pedido_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal  BIGINT := current_sucursal_id();
  v_role      TEXT;
  v_paradas   BIGINT[];
  v_afectados BIGINT[];
  v_rid       BIGINT;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay sucursal activa');
  END IF;

  SELECT rol INTO v_role FROM perfiles WHERE id = auth.uid();
  IF v_role IS NULL OR v_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  -- #1406: las rutas en curso del pedido se bloquean por id antes de borrar sus
  -- paradas, en el orden de la 439 (pedidos, rutas, paradas). Desde
  -- cancelar_pedido_con_stock ya estan tomadas, por el trigger de la entrega. El
  -- front la llama sola, y borraba la parada antes de tomar la ruta: la entrega
  -- de ese mismo pedido, que toma la ruta y despues la parada, se cruzaba con
  -- ella. El pedido no hace falta: no se escribe.
  PERFORM 1
     FROM recorridos r
    WHERE r.id IN (SELECT rp.recorrido_id
                     FROM recorrido_pedidos rp
                    WHERE rp.pedido_id   = p_pedido_id
                      AND rp.sucursal_id = v_sucursal)
      AND r.estado = 'en_curso'
    ORDER BY r.id
      FOR NO KEY UPDATE;

  -- mig 180: se guardan los recorridos tocados para recalcularlos. Sin esto
  -- total_pedidos/total_facturado quedaban contando una parada que ya no existe.
  -- #1313: el no entregado deja su rastro en el historial antes de irse.
  SELECT array_agg(rp.id), array_agg(DISTINCT rp.recorrido_id ORDER BY rp.recorrido_id)
    INTO v_paradas, v_afectados
  FROM recorrido_pedidos rp
  JOIN recorridos r ON r.id = rp.recorrido_id
  WHERE rp.pedido_id   = p_pedido_id
    AND rp.sucursal_id = v_sucursal
    AND r.estado       = 'en_curso';

  IF v_paradas IS NOT NULL THEN
    PERFORM public._no_entregas_al_historial(v_paradas);
    DELETE FROM recorrido_pedidos WHERE id = ANY(v_paradas);
    FOREACH v_rid IN ARRAY v_afectados LOOP
      PERFORM public.recalcular_recorrido(v_rid);
    END LOOP;
  END IF;

  RETURN jsonb_build_object('success', true, 'paradas_eliminadas', COALESCE(cardinality(v_paradas), 0));
END;
$function$;

DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT t.firma, t.hash, t.acl, md5(p.prosrc) AS h, p.proacl::text AS a
      FROM (VALUES
        ('public.actualizar_recorrido_entrega()', '86fdd50a205c4c25c4d701fbac5276df',
         '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.recalcular_recorrido(bigint)', '02fb88f3e4ca09188833d260c0bc502c',
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.quitar_pedido_de_recorridos_activos(bigint)', 'f9676901f4a4383ad205223522e38382',
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
      ) AS t(firma, hash, acl)
      JOIN pg_proc p ON p.oid = t.firma::regprocedure
  LOOP
    IF r.h <> r.hash OR r.a IS DISTINCT FROM r.acl THEN
      RAISE EXCEPTION '% no quedó como en el repo (md5 %, acl %)', r.firma, r.h, r.a;
    END IF;
  END LOOP;
END
$post$;

COMMIT;

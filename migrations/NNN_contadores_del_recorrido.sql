-- NNN · Dos entregas a la vez ya no dejan mal los contadores del recorrido (#1397).
--
-- QUÉ PASABA
--   actualizar_recorrido_entrega (trigger AFTER UPDATE OF estado, monto_pagado, total de
--   pedidos) recalcula cada ruta del pedido con
--     UPDATE recorridos r SET ... FROM _recorrido_contadores(v_rid) c WHERE r.id = v_rid.
--   Con dos entregas de la misma ruta a la vez, la segunda espera la fila de recorridos y,
--   en READ COMMITTED, al despertar relee esa fila pero no vuelve a correr
--   _recorrido_contadores: escribe un conteo de antes del COMMIT de la primera. La ruta
--   quedaba con un entregado de menos (y lo mismo total_cobrado y total_facturado) hasta
--   el próximo evento que la recalculara. El arnés de #1288 lo midió (C7h): 161 de 200
--   rondas con pedidos_entregados mal. Es lo mismo que #1247 con monto_pagado.
--
-- QUÉ CAMBIA
--   Antes del bucle que recalcula, un PERFORM bloquea todas las rutas del pedido por id
--   (FOR NO KEY UPDATE, el lock que el UPDATE iba a tomar igual). La espera pasa a esa
--   sentencia, y cada UPDATE de abajo arranca con una foto nueva que ya ve la otra entrega.
--   El orden es el de la 439: el pedido (lo tiene el UPDATE que disparó el trigger) y
--   después sus recorridos por id, como el bucle ya los recorría.
--
-- QUÉ NO CAMBIA
--   Qué parada se marca, qué rutas se recalculan y con qué cuenta. La firma, el EXECUTE y
--   el resto del cuerpo.
--
-- Ensayo: scripts/test-contadores-recorrido-1397.sql, y C7h del arnés (scripts/concurrencia).
-- Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

DO $premisa$
BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.actualizar_recorrido_entrega()'::regprocedure)
     <> '99252000e6b688504e5d1dce78eee35b' THEN
    RAISE EXCEPTION 'actualizar_recorrido_entrega cambió en prod (md5 %): rehacer el parche sobre el cuerpo vigente',
      (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.actualizar_recorrido_entrega()'::regprocedure);
  END IF;
END
$premisa$;

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
  -- nada). Es recalculo, no delta, y sale de _recorrido_contadores. Las filas
  -- de recorridos se bloquean por id ascendente.
  --
  -- #1397: el lock va en su propia sentencia y ANTES de recalcular, como en
  -- recalcular_monto_pagado_pedido (#1247). Un UPDATE que espera la fila
  -- re-evalua el WHERE contra la version nueva, pero _recorrido_contadores ya
  -- corrio con la foto de su sentencia: si otra transaccion entregaba otro
  -- pedido de la misma ruta, el conteo no la veia y la pisaba. Despues de este
  -- PERFORM cada UPDATE de abajo arranca con una foto nueva. Todas juntas y por
  -- id: el orden de la 439, pedidos y despues recorridos.
  PERFORM 1
     FROM recorridos r
    WHERE r.id IN (SELECT rp.recorrido_id
                     FROM recorrido_pedidos rp
                    WHERE rp.pedido_id = NEW.id)
    ORDER BY r.id
      FOR NO KEY UPDATE;

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

COMMIT;

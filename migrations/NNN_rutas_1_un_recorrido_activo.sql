-- ============================================================================
-- NNN · Rutas 1: un pedido vive en un solo recorrido (#1313, plan #1308 tarjeta 2)
-- ============================================================================
-- El número se elige al aplicarla, contra el ledger de prod y origin/main
-- (trampa 3 de CLAUDE.md). Aplicar desde el contenido LF.
--
-- QUÉ ES ESTO
-- -----------
-- LOG-3 · un pedido quedaba en dos recorridos. `aplicar_orden_ruta` lo sumaba
--   a la ruta nueva sin sacarlo de la anterior, y `actualizar_recorrido_entrega`
--   y `recalcular_recorrido` contaban la entrega en TODAS las rutas del pedido:
--   A no lo entrega, B sí, y figura entregado y cobrado en las dos.
--   Ahora, al entrar a una ruta, el pedido sale de las demás:
--     · de una ruta EN CURSO se borra la parada (como ya hacía "Volver a
--       pendiente"): las guardas de edición, RUTA-C y la hoja de ruta leen
--       "parada en una ruta en curso" como "el pedido está en la calle";
--     · de una ruta CERRADA (completada o cancelada) la parada pendiente queda
--       'reasignado', un estado nuevo: la ruta la tuvo, pero ya no es suya.
--   Una parada 'no_entregado' o 'reasignado' es historia: no cuenta en ningún
--   contador de su ruta y la entrega nunca se marca ahí. Los contadores salen
--   de UNA función, `_recorrido_contadores`, que usan las tres que los
--   escribían (y ahora también "Volver a pendiente").
-- LOG-4 · reordenar una ruta perdía la marca de no entregado: el DELETE la
--   borraba sin rastro, o el ON CONFLICT la dejaba puesta en un pedido que
--   volvía a salir. Ahora, toda vez que una parada 'no_entregado' sale de una
--   ruta en curso —reorden, otra ruta, volver a pendiente, cancelación (por
--   `quitar_pedido_de_recorridos_activos`)— o vuelve a salir en la misma, el
--   intento queda en `pedido_historial` (campo 'no_entrega', con la ruta, el
--   chofer, el motivo, la nota y la hora del intento: `_no_entregas_al_historial`).
--   Si el pedido vuelve a salir en la misma ruta, la parada vuelve a
--   'pendiente' limpia. Además, el "devolver a preparación" de lo que sale de
--   la ruta ya no toca un pedido que hoy es de otro chofer.
-- Entrega y reversión (`actualizar_recorrido_entrega`): la entrega va a la
--   parada viva del pedido. Si no tiene —el chofer lo marcó no entregado y el
--   admin igual confirma la entrega sin re-rutearlo—, va a la 'no_entregado'
--   de la ruta en curso, como antes, y el intento queda en el historial. Y al
--   revertir una entrega la parada vuelve a 'pendiente' (antes sólo lo hacía
--   `recalcular_recorrido` a mano, y mientras tanto la parada seguía
--   'entregado' con el pedido en la calle).
-- LOG-5 · `actualizar_orden_entrega_batch` y `limpiar_orden_entrega` no las
--   llama nadie (ni el front, ni las edge functions, ni otra función) y no
--   miraban de quién era la ruta: se dropean. `recorridos.estado` queda con
--   CHECK y NOT NULL, y por REST (el chofer cerrando su ruta) sólo puede pasar
--   de 'en_curso' a 'completado'; `completed_at` lo pone el servidor.
-- LOG-6 · `cambiar_transportista_recorrido` le pasaba al chofer nuevo todo
--   pedido no entregado de la ruta, también uno que ya había vuelto a
--   pendiente o se había cancelado. Ahora sólo los 'asignado' al chofer viejo
--   con la parada pendiente. Y las FKs de `recorridos` y `rendiciones` a
--   `perfiles` pasan de CASCADE a RESTRICT: un perfil no se borra, se
--   desactiva. ("Volver a pendiente" en una RPC va en NNN_rutas_2.)
-- #1277 · `aplicar_orden_ruta` sin fecha usaba CURRENT_DATE (UTC): pasa a
--   `_tablero_hoy()` y sale de scripts/fechas-utc-permitidas.json.
--
-- QUÉ SE TOCA
-- -----------
-- Nuevas, sólo de servidor: _recorrido_contadores(bigint),
--   _no_entregas_al_historial(bigint[]).
-- Nueva, de trigger: recorridos_estado_transicion() + trg_recorridos_estado.
-- Reemplazadas sobre el cuerpo vivo (md5 verificado en el paso 0):
--   actualizar_recorrido_entrega, aplicar_orden_ruta,
--   cambiar_transportista_recorrido, quitar_pedido_de_recorridos_activos,
--   recalcular_recorrido (misma firma y misma guarda).
-- Dropeadas: actualizar_orden_entrega_batch(jsonb), limpiar_orden_entrega(uuid).
-- Tablas: CHECK de recorridos.estado y recorrido_pedidos.estado_entrega; FKs
--   recorridos_transportista_id_fkey y rendiciones_transportista_id_fkey.
-- Sin cambios de grants REST: `recorridos.UPDATE (completed_at, estado)` sigue
--   (el chofer cierra su ruta), ahora con la transición validada.
-- Locks: el trigger de entrega bloquea las filas de recorridos del pedido por
--   id ascendente, después de la fila del pedido que lo disparó; no toca
--   productos. Es el mismo trigger y las mismas filas que antes.
-- No se toca `marcar_no_entregado` ni `auditoria_integridad()`. RUTA-A y
--   RUTA-B tienen que pasar a `_recorrido_contadores` y a las paradas vivas
--   (anotado en #1330, tarjeta 8): se ponen rojos cuando quede historia en una
--   ruta CERRADA y el pedido se entregue en otra. Hoy no hay ninguna parada en
--   historia, así que siguen en 0 al aplicar esta migración.
-- No se corrigen los 23 pedidos de junio (rutas 7 a 10, todas con la parada
--   entregada): marcarlos ahora pone rojo RUTA-B hasta #1330.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Premisas
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(pg_get_functiondef(x.firma::regprocedure)) AS md5_vivo
      FROM (VALUES
        ('public.actualizar_recorrido_entrega()',                                  '5a833d582f164befc4bf9f5fe667bbd4'),
        ('public.aplicar_orden_ruta(uuid,jsonb,numeric,integer,jsonb,date)',       '47714a4f9aaa9befad978f224fdfe7ae'),
        ('public.cambiar_transportista_recorrido(bigint,uuid)',                    'feacce80bf2ad32be57f3b18660cbc98'),
        ('public.quitar_pedido_de_recorridos_activos(bigint)',                     '45f09bf167a174b31bcb655d6e995c3d'),
        ('public.recalcular_recorrido(bigint)',                                    '5cadc66edca233beb8eaab8c65199356'),
        ('public.actualizar_orden_entrega_batch(jsonb)',                           '41ac5c9a503f6f85f93eaead98e2c248'),
        ('public.limpiar_orden_entrega(uuid)',                                     '82c11a2045031d8c11cbaa53430ab87d')
      ) AS x(firma, md5)
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig NNN · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;

  -- Las dos que se dropean no las llama ninguna otra función.
  IF EXISTS (
    SELECT 1 FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
       AND p.proname NOT IN ('actualizar_orden_entrega_batch', 'limpiar_orden_entrega')
       AND pg_get_functiondef(p.oid) ~ '(actualizar_orden_entrega_batch|limpiar_orden_entrega)'
  ) THEN
    RAISE EXCEPTION 'mig NNN · una función llama a actualizar_orden_entrega_batch o limpiar_orden_entrega';
  END IF;

  -- Los CHECK nuevos valen para lo que hay.
  IF EXISTS (SELECT 1 FROM recorridos WHERE estado IS NULL OR estado NOT IN ('en_curso', 'completado', 'cancelado')) THEN
    RAISE EXCEPTION 'mig NNN · hay recorridos con un estado fuera de en_curso/completado/cancelado';
  END IF;
  IF EXISTS (SELECT 1 FROM recorrido_pedidos WHERE estado_entrega IS NULL OR estado_entrega NOT IN ('pendiente', 'entregado', 'no_entregado')) THEN
    RAISE EXCEPTION 'mig NNN · hay paradas con un estado_entrega desconocido';
  END IF;
  -- Sin historia hoy: la cuenta nueva da lo mismo que la vieja en toda ruta.
  IF EXISTS (SELECT 1 FROM recorrido_pedidos WHERE estado_entrega = 'no_entregado') THEN
    RAISE EXCEPTION 'mig NNN · hay paradas no_entregado: revisar el cierre de contadores antes de aplicar';
  END IF;
END
$premisas$;

-- Foto de los contadores antes de tocar nada (se compara en el cierre).
CREATE TEMP TABLE _nnn_contadores_antes ON COMMIT DROP AS
  SELECT id, total_pedidos, total_facturado, pedidos_entregados, total_cobrado FROM recorridos;

-- ---------------------------------------------------------------------------
-- 1 · Los estados
-- ---------------------------------------------------------------------------
ALTER TABLE public.recorridos ALTER COLUMN estado SET NOT NULL;
ALTER TABLE public.recorridos
  ADD CONSTRAINT recorridos_estado_valido
  CHECK (estado IN ('en_curso', 'completado', 'cancelado'));

ALTER TABLE public.recorrido_pedidos ALTER COLUMN estado_entrega SET NOT NULL;
ALTER TABLE public.recorrido_pedidos
  ADD CONSTRAINT recorrido_pedidos_estado_entrega_valido
  CHECK (estado_entrega IN ('pendiente', 'entregado', 'no_entregado', 'reasignado'));

COMMENT ON COLUMN public.recorrido_pedidos.estado_entrega IS
  'pendiente | entregado: la parada viva del pedido. no_entregado (el chofer no pudo, mig 144) | reasignado (estaba en una ruta cerrada y pasó a otra): historia, no cuenta en los contadores de la ruta ni recibe la entrega (#1313).';

-- ---------------------------------------------------------------------------
-- 2 · Los contadores: una sola cuenta
-- ---------------------------------------------------------------------------
CREATE FUNCTION public._recorrido_contadores(p_recorrido_id bigint)
RETURNS TABLE (total_pedidos integer, total_facturado numeric, pedidos_entregados integer, total_cobrado numeric)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  -- Sólo las paradas vivas: el pedido no entregado acá, o que pasó a otra
  -- ruta, no es una parada que la ruta tenga que hacer, facturar ni cobrar
  -- (#1313). Así "pendientes = total - entregados" (bot, /recorridos) cierra.
  SELECT (COUNT(*) FILTER (WHERE rp.estado_entrega IN ('pendiente', 'entregado')))::integer,
         COALESCE(SUM(p.total) FILTER (
           WHERE rp.estado_entrega IN ('pendiente', 'entregado')
             AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB'), 0),
         (COUNT(*) FILTER (
           WHERE rp.estado_entrega IN ('pendiente', 'entregado')
             AND p.estado = 'entregado'))::integer,
         COALESCE(SUM(p.monto_pagado) FILTER (
           WHERE rp.estado_entrega IN ('pendiente', 'entregado')
             AND p.estado = 'entregado'
             AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB'), 0)
    FROM recorrido_pedidos rp
    JOIN pedidos p ON p.id = rp.pedido_id
   WHERE rp.recorrido_id = p_recorrido_id;
$function$;

ALTER FUNCTION public._recorrido_contadores(bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public._recorrido_contadores(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._recorrido_contadores(bigint) TO service_role;
COMMENT ON FUNCTION public._recorrido_contadores(bigint) IS
  'Los cuatro contadores de una ruta desde sus paradas vivas (pendiente, entregado); la historia (no_entregado, reasignado) no cuenta (#1313). La usan actualizar_recorrido_entrega, aplicar_orden_ruta, recalcular_recorrido y volver_pedido_a_pendiente.';

-- ---------------------------------------------------------------------------
-- 3 · El rastro del no entregado
-- ---------------------------------------------------------------------------
CREATE FUNCTION public._no_entregas_al_historial(p_paradas bigint[])
RETURNS void
LANGUAGE sql
SET search_path TO 'public'
AS $function$
  -- De las paradas dadas, las 'no_entregado' dejan el intento en el historial
  -- del pedido antes de borrarse o reabrirse (#1313, LOG-4). A nombre del
  -- chofer de la ruta, con la hora del intento.
  INSERT INTO pedido_historial
    (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, created_at, sucursal_id)
  SELECT rp.pedido_id,
         r.transportista_id,
         'no_entrega',
         format('Ruta #%s', rp.recorrido_id),
         COALESCE(NULLIF(concat_ws(': ', rp.motivo_no_entrega, rp.nota_no_entrega), ''), 'sin motivo'),
         COALESCE(rp.hora_entrega, now()),
         rp.sucursal_id
    FROM recorrido_pedidos rp
    JOIN recorridos r ON r.id = rp.recorrido_id
   WHERE rp.id = ANY(p_paradas)
     AND rp.estado_entrega = 'no_entregado';
$function$;

ALTER FUNCTION public._no_entregas_al_historial(bigint[]) OWNER TO postgres;
REVOKE ALL ON FUNCTION public._no_entregas_al_historial(bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._no_entregas_al_historial(bigint[]) TO service_role;
COMMENT ON FUNCTION public._no_entregas_al_historial(bigint[]) IS
  'Copia a pedido_historial (campo no_entrega) las paradas no_entregado dadas, antes de que se borren o se reabran (#1313). Sólo la llaman las RPCs de rutas.';

-- ---------------------------------------------------------------------------
-- 4 · actualizar_recorrido_entrega: la entrega va a la parada viva
-- ---------------------------------------------------------------------------
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
  -- con datos de antes de la mig NNN. Sin filtro de fecha: el guard
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

-- ---------------------------------------------------------------------------
-- 5 · aplicar_orden_ruta: el pedido sale de las otras rutas, con rastro
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.aplicar_orden_ruta(p_transportista_id uuid, p_pedidos jsonb, p_distancia numeric DEFAULT NULL::numeric, p_duracion integer DEFAULT NULL::integer, p_polylines jsonb DEFAULT NULL::jsonb, p_fecha date DEFAULT NULL::date)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  -- #1277: el día argentino, no el del servidor.
  v_fecha date := COALESCE(p_fecha, public._tablero_hoy());
  v_item jsonb;
  v_recorrido_id BIGINT;
  v_nuevos BIGINT[];
  v_entran BIGINT[];
  v_paradas BIGINT[];
  v_otras BIGINT[];
  v_rid BIGINT;
BEGIN
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado para aplicar orden de ruta' USING ERRCODE = '42501';
  END IF;

  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'Sucursal no resuelta para el usuario actual';
  END IF;

  IF p_pedidos IS NULL OR jsonb_array_length(p_pedidos) = 0 THEN
    RAISE EXCEPTION 'No hay pedidos para aplicar orden';
  END IF;

  SELECT array_agg((value->>'pedido_id')::BIGINT)
    INTO v_nuevos
  FROM jsonb_array_elements(p_pedidos);

  SELECT id INTO v_recorrido_id
  FROM recorridos
  WHERE transportista_id = p_transportista_id
    AND fecha = v_fecha
    AND estado = 'en_curso'
    AND sucursal_id = v_sucursal
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_recorrido_id IS NOT NULL THEN
    -- Lo que sale de la ruta vuelve a preparación. Sólo si sigue siendo de
    -- ESTE chofer: un pedido no entregado acá y ya asignado a otro no se toca
    -- (#1313).
    UPDATE pedidos p
    SET estado = 'en_preparacion',
        transportista_id = NULL,
        orden_entrega = NULL
    FROM recorrido_pedidos rp
    WHERE rp.recorrido_id = v_recorrido_id
      AND rp.pedido_id = p.id
      AND p.sucursal_id = v_sucursal
      AND p.estado = 'asignado'
      AND p.transportista_id = p_transportista_id
      AND NOT (rp.pedido_id = ANY(v_nuevos));

    -- Se borran las paradas que salen (menos las de pedidos entregados, que
    -- siguen figurando en la hoja de ruta). El no entregado deja su rastro en
    -- el historial antes de irse (#1313, LOG-4).
    SELECT array_agg(rp.id)
      INTO v_paradas
    FROM recorrido_pedidos rp
    JOIN pedidos p ON p.id = rp.pedido_id
    WHERE rp.recorrido_id = v_recorrido_id
      AND p.estado <> 'entregado'
      AND NOT (rp.pedido_id = ANY(v_nuevos));

    IF v_paradas IS NOT NULL THEN
      PERFORM public._no_entregas_al_historial(v_paradas);
      DELETE FROM recorrido_pedidos WHERE id = ANY(v_paradas);
    END IF;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_pedidos) LOOP
    UPDATE pedidos
    SET transportista_id = p_transportista_id,
        estado = 'asignado',
        orden_entrega = (v_item->>'orden_entrega')::INTEGER
    WHERE id = (v_item->>'pedido_id')::BIGINT
      AND sucursal_id = v_sucursal
      -- mig 180: re-armar la ruta no puede devolver a 'asignado' algo que ya
      -- se entrego o se cancelo.
      AND estado NOT IN ('entregado', 'cancelado', 'anulado');
  END LOOP;

  -- Los que de verdad salen en esta ruta: los que quedaron asignados.
  SELECT COALESCE(array_agg(p.id), '{}')
    INTO v_entran
  FROM pedidos p
  WHERE p.id = ANY(v_nuevos)
    AND p.sucursal_id = v_sucursal
    AND p.estado NOT IN ('entregado', 'cancelado', 'anulado');

  IF v_recorrido_id IS NULL THEN
    INSERT INTO recorridos
      (transportista_id, fecha, distancia_total, duracion_total, total_pedidos,
       total_facturado, estado, sucursal_id, polylines)
    VALUES
      (p_transportista_id, v_fecha, p_distancia, p_duracion,
       jsonb_array_length(p_pedidos), 0, 'en_curso', v_sucursal, p_polylines)
    RETURNING id INTO v_recorrido_id;
  ELSE
    UPDATE recorridos
    SET distancia_total = p_distancia,
        duracion_total = p_duracion,
        polylines = p_polylines,
        estado = 'en_curso'
    WHERE id = v_recorrido_id;
  END IF;

  -- #1313: un pedido vive en una sola ruta. El que entra sale de las demás.
  -- a) De una ruta en curso se borra su parada (no entregada: el pedido no lo
  --    está), con el rastro del no entregado en el historial.
  SELECT array_agg(rp.id), array_agg(DISTINCT rp.recorrido_id)
    INTO v_paradas, v_otras
  FROM recorrido_pedidos rp
  JOIN recorridos r ON r.id = rp.recorrido_id
  WHERE rp.pedido_id = ANY(v_entran)
    AND rp.recorrido_id <> v_recorrido_id
    AND rp.sucursal_id = v_sucursal
    AND rp.estado_entrega <> 'entregado'
    AND r.estado = 'en_curso';

  IF v_paradas IS NOT NULL THEN
    PERFORM public._no_entregas_al_historial(v_paradas);
    DELETE FROM recorrido_pedidos WHERE id = ANY(v_paradas);
  END IF;

  -- b) De una ruta cerrada, la parada pendiente queda 'reasignado' (la ruta
  --    la tuvo; el no entregado ya es historia y se queda como está).
  WITH reasignadas AS (
    UPDATE recorrido_pedidos rp
       SET estado_entrega = 'reasignado'
      FROM recorridos r
     WHERE r.id = rp.recorrido_id
       AND rp.pedido_id = ANY(v_entran)
       AND rp.recorrido_id <> v_recorrido_id
       AND rp.sucursal_id = v_sucursal
       AND rp.estado_entrega = 'pendiente'
       AND r.estado <> 'en_curso'
    RETURNING rp.recorrido_id
  )
  SELECT array_agg(DISTINCT x) INTO v_otras
  FROM (SELECT unnest(COALESCE(v_otras, '{}')) AS x
        UNION SELECT recorrido_id FROM reasignadas) u;

  -- c) Si uno que no se entregó acá vuelve a salir en la MISMA ruta, el
  --    intento va al historial y la parada se reabre limpia (ON CONFLICT).
  SELECT array_agg(rp.id)
    INTO v_paradas
  FROM recorrido_pedidos rp
  WHERE rp.recorrido_id = v_recorrido_id
    AND rp.pedido_id = ANY(v_entran)
    AND rp.estado_entrega = 'no_entregado';

  IF v_paradas IS NOT NULL THEN
    PERFORM public._no_entregas_al_historial(v_paradas);
  END IF;

  -- Las paradas: las de los pedidos que salen, y el reorden de las que ya
  -- estaban (una entregada sigue figurando en la hoja de ruta, mig 180). Un
  -- pedido entregado o cancelado que no estaba en esta ruta no entra (#1313,
  -- RUTA-C).
  INSERT INTO recorrido_pedidos (recorrido_id, pedido_id, orden_entrega, sucursal_id)
  SELECT v_recorrido_id,
         (value->>'pedido_id')::BIGINT,
         (value->>'orden_entrega')::INTEGER,
         v_sucursal
  FROM jsonb_array_elements(p_pedidos)
  WHERE (value->>'pedido_id')::BIGINT = ANY(v_entran)
     OR EXISTS (SELECT 1 FROM recorrido_pedidos rp
                 WHERE rp.recorrido_id = v_recorrido_id
                   AND rp.pedido_id = (value->>'pedido_id')::BIGINT)
  ON CONFLICT (recorrido_id, pedido_id)
  DO UPDATE SET
    orden_entrega     = EXCLUDED.orden_entrega,
    estado_entrega    = CASE WHEN recorrido_pedidos.estado_entrega = 'no_entregado'
                              AND EXCLUDED.pedido_id = ANY(v_entran)
                             THEN 'pendiente' ELSE recorrido_pedidos.estado_entrega END,
    motivo_no_entrega = CASE WHEN recorrido_pedidos.estado_entrega = 'no_entregado'
                              AND EXCLUDED.pedido_id = ANY(v_entran)
                             THEN NULL ELSE recorrido_pedidos.motivo_no_entrega END,
    nota_no_entrega   = CASE WHEN recorrido_pedidos.estado_entrega = 'no_entregado'
                              AND EXCLUDED.pedido_id = ANY(v_entran)
                             THEN NULL ELSE recorrido_pedidos.nota_no_entrega END,
    hora_entrega      = CASE WHEN recorrido_pedidos.estado_entrega = 'no_entregado'
                              AND EXCLUDED.pedido_id = ANY(v_entran)
                             THEN NULL ELSE recorrido_pedidos.hora_entrega END;

  FOREACH v_rid IN ARRAY (SELECT array_agg(DISTINCT x ORDER BY x)
                            FROM unnest(array_append(COALESCE(v_otras, '{}'), v_recorrido_id)) AS x) LOOP
    UPDATE recorridos r
    SET total_pedidos      = c.total_pedidos,
        total_facturado    = c.total_facturado,
        pedidos_entregados = c.pedidos_entregados,
        total_cobrado      = c.total_cobrado
    FROM public._recorrido_contadores(v_rid) c
    WHERE r.id = v_rid;
  END LOOP;

  RETURN v_recorrido_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6 · cambiar_transportista_recorrido: no arrastra lo que ya no es de la ruta
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cambiar_transportista_recorrido(p_recorrido_id bigint, p_transportista_id uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal   bigint := current_sucursal_id();
  v_recorrido  recorridos%ROWTYPE;
  v_entregadas integer;
  v_conflicto  bigint;
  v_nombre     text;
BEGIN
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado para cambiar el transportista de una ruta'
      USING ERRCODE = '42501';
  END IF;

  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'Sucursal no resuelta para el usuario actual';
  END IF;

  IF p_transportista_id IS NULL THEN
    RAISE EXCEPTION 'Hay que elegir un transportista';
  END IF;

  -- FOR UPDATE: sin el lock, dos admins reasignando en paralelo pueden pasar
  -- los dos el chequeo de uq_recorrido_vigente y uno se come el 23505.
  SELECT * INTO v_recorrido
  FROM recorridos
  WHERE id = p_recorrido_id
    AND sucursal_id = v_sucursal
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La ruta #% no existe en esta sucursal', p_recorrido_id
      USING ERRCODE = 'P0002';
  END IF;

  IF v_recorrido.transportista_id = p_transportista_id THEN
    RETURN p_recorrido_id;  -- ya esta a su nombre: no-op
  END IF;

  IF v_recorrido.estado <> 'en_curso' THEN
    RAISE EXCEPTION 'La ruta #% esta %, solo se puede reasignar una ruta en curso',
      p_recorrido_id, v_recorrido.estado;
  END IF;

  -- Habilitado como transportista EN ESTA SUCURSAL (rol base o mig 155),
  -- activo y asignado aca. Espeja fetchTransportistas() del front.
  SELECT p.nombre INTO v_nombre
  FROM perfiles p
  WHERE p.id = p_transportista_id
    AND p.activo
    AND EXISTS (
      SELECT 1 FROM usuario_sucursales us
      WHERE us.usuario_id = p.id AND us.sucursal_id = v_sucursal
    )
    AND (
      p.rol = 'transportista'
      OR EXISTS (
        SELECT 1 FROM perfil_roles pr
        WHERE pr.usuario_id  = p.id
          AND pr.sucursal_id = v_sucursal
          AND pr.rol         = 'transportista'
      )
    );

  IF v_nombre IS NULL THEN
    RAISE EXCEPTION 'El usuario elegido no esta habilitado como transportista en esta sucursal';
  END IF;

  -- Entregas ya hechas EN ESTA RUTA: la rendicion del dia quedaria partida
  -- entre dos. Una parada en historia no cuenta (#1313).
  SELECT COUNT(*) INTO v_entregadas
  FROM recorrido_pedidos rp
  JOIN pedidos p ON p.id = rp.pedido_id
  WHERE rp.recorrido_id = p_recorrido_id
    AND rp.estado_entrega IN ('pendiente', 'entregado')
    AND (rp.estado_entrega = 'entregado' OR p.estado = 'entregado');

  IF v_entregadas > 0 THEN
    RAISE EXCEPTION
      'La ruta #% ya tiene % entrega(s) hecha(s) por %. Sacale esas paradas o armale una ruta nueva al otro chofer.',
      p_recorrido_id,
      v_entregadas,
      COALESCE((SELECT nombre FROM perfiles WHERE id = v_recorrido.transportista_id), 'el chofer actual');
  END IF;

  -- uq_recorrido_vigente (transportista_id, fecha, sucursal_id) WHERE en_curso
  SELECT id INTO v_conflicto
  FROM recorridos
  WHERE transportista_id = p_transportista_id
    AND fecha            = v_recorrido.fecha
    AND sucursal_id      = v_sucursal
    AND estado           = 'en_curso'
  LIMIT 1;

  IF v_conflicto IS NOT NULL THEN
    RAISE EXCEPTION
      '% ya tiene la ruta #% armada para el %. Pasale las paradas a esa en vez de duplicarla.',
      v_nombre, v_conflicto, to_char(v_recorrido.fecha, 'DD/MM/YYYY');
  END IF;

  UPDATE recorridos
  SET transportista_id = p_transportista_id
  WHERE id = p_recorrido_id;

  -- Los pedidos tambien: `pedidos.transportista_id` es lo que leen la PWA del
  -- chofer, las policies de `pagos` (mig 155) y la rendicion. Sin esto la ruta
  -- cambia de nombre en el listado y el chofer nuevo no la ve.
  -- Sólo los que la ruta todavía reparte (#1313): asignados al chofer viejo y
  -- con la parada pendiente. Uno que volvió a pendiente (p. ej. no entregado),
  -- se canceló o ya es de otro chofer no se arrastra.
  UPDATE pedidos p
  SET transportista_id = p_transportista_id
  FROM recorrido_pedidos rp
  WHERE rp.recorrido_id   = p_recorrido_id
    AND p.id              = rp.pedido_id
    AND p.sucursal_id     = v_sucursal
    AND rp.estado_entrega = 'pendiente'
    AND p.estado          = 'asignado'
    AND p.transportista_id IS NOT DISTINCT FROM v_recorrido.transportista_id;

  RETURN p_recorrido_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 7 · quitar_pedido_de_recorridos_activos: con el rastro del no entregado
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 8 · recalcular_recorrido: realinea sólo la parada viva, cuenta con el helper
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 9 · La transición de recorridos.estado por REST
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.recorridos_estado_transicion()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Las RPCs (SECURITY DEFINER, corren como su dueño) y el servidor manejan el
  -- estado a su manera. Por REST —el grant de `recorridos.UPDATE (completed_at,
  -- estado)` es para que el chofer cierre su ruta— sólo vale en_curso →
  -- completado, y la hora la pone el servidor (#1313, LOG-5). Un completed_at
  -- que mande el cliente se ignora (p. ej. completar una ruta que ya cerró el
  -- cron no falla: queda como estaba).
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  IF NEW.estado IS DISTINCT FROM OLD.estado THEN
    IF NOT (OLD.estado = 'en_curso' AND NEW.estado = 'completado') THEN
      RAISE EXCEPTION 'Una ruta % no puede pasar a % desde la app: sólo se completa una ruta en curso',
        OLD.estado, NEW.estado
        USING ERRCODE = '42501';
    END IF;
    NEW.completed_at := now();
  ELSE
    NEW.completed_at := OLD.completed_at;
  END IF;

  RETURN NEW;
END;
$function$;

ALTER FUNCTION public.recorridos_estado_transicion() OWNER TO postgres;
-- Trigger: la invoca el executor, no el caller (CLAUDE.md).
REVOKE ALL ON FUNCTION public.recorridos_estado_transicion() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recorridos_estado_transicion() TO service_role;

CREATE TRIGGER trg_recorridos_estado
  BEFORE UPDATE OF estado, completed_at ON public.recorridos
  FOR EACH ROW EXECUTE FUNCTION public.recorridos_estado_transicion();

-- ---------------------------------------------------------------------------
-- 10 · Las dos sin uso
-- ---------------------------------------------------------------------------
DROP FUNCTION public.actualizar_orden_entrega_batch(jsonb);
DROP FUNCTION public.limpiar_orden_entrega(uuid);

-- ---------------------------------------------------------------------------
-- 11 · Un perfil no se borra, se desactiva
-- ---------------------------------------------------------------------------
ALTER TABLE public.recorridos DROP CONSTRAINT recorridos_transportista_id_fkey;
ALTER TABLE public.recorridos
  ADD CONSTRAINT recorridos_transportista_id_fkey
  FOREIGN KEY (transportista_id) REFERENCES public.perfiles(id) ON DELETE RESTRICT;

ALTER TABLE public.rendiciones DROP CONSTRAINT rendiciones_transportista_id_fkey;
ALTER TABLE public.rendiciones
  ADD CONSTRAINT rendiciones_transportista_id_fkey
  FOREIGN KEY (transportista_id) REFERENCES public.perfiles(id) ON DELETE RESTRICT;

-- ---------------------------------------------------------------------------
-- 12 · Cierre: los contadores no se mueven y los grants quedan como deben
-- ---------------------------------------------------------------------------
DO $cierre$
DECLARE
  v_n int;
BEGIN
  SELECT count(*) INTO v_n
    FROM _nnn_contadores_antes a
    CROSS JOIN LATERAL public._recorrido_contadores(a.id) c
   WHERE a.total_pedidos      IS DISTINCT FROM c.total_pedidos
      OR COALESCE(a.total_facturado, 0) IS DISTINCT FROM c.total_facturado
      OR a.pedidos_entregados IS DISTINCT FROM c.pedidos_entregados
      OR COALESCE(a.total_cobrado, 0)   IS DISTINCT FROM c.total_cobrado;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig NNN · % rutas cambian de contadores con la cuenta nueva: no debería moverse ninguna', v_n;
  END IF;

  IF has_function_privilege('authenticated', 'public._recorrido_contadores(bigint)', 'EXECUTE')
     OR has_function_privilege('anon', 'public._recorrido_contadores(bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._no_entregas_al_historial(bigint[])', 'EXECUTE')
     OR has_function_privilege('anon', 'public._no_entregas_al_historial(bigint[])', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.recorridos_estado_transicion()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.recorridos_estado_transicion()', 'EXECUTE') THEN
    RAISE EXCEPTION 'mig NNN · una función nueva quedó ejecutable por anon o authenticated';
  END IF;

  IF has_function_privilege('anon', 'public.aplicar_orden_ruta(uuid,jsonb,numeric,integer,jsonb,date)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cambiar_transportista_recorrido(bigint,uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.quitar_pedido_de_recorridos_activos(bigint)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.recalcular_recorrido(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'mig NNN · una RPC de rutas quedó ejecutable por anon';
  END IF;
END
$cierre$;

COMMIT;

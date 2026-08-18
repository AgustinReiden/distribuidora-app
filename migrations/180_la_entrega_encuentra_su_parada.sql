-- =========================================================================
-- 180_la_entrega_encuentra_su_parada.sql
--
-- La ruta no se entera de casi ninguna entrega, y no habia forma de repararlo.
--
-- EL SINTOMA
-- ----------
-- Recorrido 90 (14/08, 36 paradas): la pantalla de Recorridos dice 1 entrega y
-- $20.300 cobrados. La realidad son 34 entregas y $1.216.650. El 76 dice 0 y
-- $0 contra 19 entregas y $1.725.170.
--
-- Al 18/08 en produccion:
--   · 1.455 de 2.047 paradas tienen el pedido en 'entregado' y la parada no.
--   · 78 de 86 recorridos (91%) tienen pedidos_entregados y/o total_cobrado mal.
--   · La diferencia acumulada de total_cobrado es de $58.717.569.
--   · 118 paradas son de pedidos cancelados.
--
-- El encargado abre Recorridos, ve "Pendiente de cobro $1.252.990" y sale a
-- reclamarle al chofer plata que el chofer ya rindio.
--
-- CAUSA 1: el guard de fecha del trigger
-- --------------------------------------
-- `actualizar_recorrido_entrega()` (mig 173) busca la parada asi:
--
--     WHERE rp.pedido_id = NEW.id
--       AND r.fecha      = CURRENT_DATE      <-- aca
--       AND r.estado     = 'en_curso'
--     IF v_recorrido_id IS NULL THEN RETURN NEW;   -- se va en silencio
--
-- La mig 173:48-50 lo dejo a proposito ("marcar una entrega al dia siguiente
-- sigue sin mover contadores historicos"). Ese "sigue sin" resulto ser el 79%
-- del volumen, porque el atajo habitual para ponerse al dia es la entrega
-- masiva del dia siguiente. Experimento natural sobre las rutas posteriores a
-- la 173, comparando r.fecha contra la fecha real del cambio de estado
-- (pedido_historial.created_at, que es el insert real y no es backdateable):
--
--     marcadas el dia de la ruta   -> 135 paradas, 135 sincronizadas
--     marcadas al dia siguiente    -> 104 paradas,   0 sincronizadas
--
-- Separacion perfecta. Y hay un agravante que no depende del operador:
-- `CURRENT_DATE` se evalua con TimeZone = 'UTC' (verificado en prod), asi que
-- a partir de las 21:00 ART el guard ya falla para el chofer que esta
-- entregando en vivo.
--
-- Ahora la parada se busca por `pedido_id` y nada mas. La fecha no dice nada
-- sobre a que parada corresponde una entrega: el pedido si.
--
-- CAUSA 2: no existia forma de reparar lo ya roto
-- -----------------------------------------------
-- Estos contadores los escribe un unico trigger condicional. Si el guard no
-- pasa, el dato queda mal para siempre: un barrido de pg_proc por
-- %recalcul%/%repar%/%sincroniz% no devuelve ningun candidato. Por eso la mig
-- 173 arreglo el trigger y dejo 1.331 paradas rotas (hoy 1.455), y por eso la
-- reparacion de la ruta 82 que el MANIFEST le atribuye no esta versionada.
--
-- Se agrega `recalcular_recorrido(id)`: idempotente, invocable a mano, y la
-- unica fuente de verdad son los pedidos. El backfill de abajo la corre sobre
-- los 86 recorridos.
--
-- La `hora_entrega` historica se reconstruye desde `pedido_historial` (la
-- transicion a 'entregado'), no con now(): las 1.455 paradas desalineadas
-- tienen las 1.455 su fila de historial, asi que la hora es exacta.
--
-- CAUSA 3: re-armar la ruta revivia las entregas
-- ----------------------------------------------
-- `aplicar_orden_ruta` (mig 088) hace `UPDATE pedidos SET estado='asignado'`
-- para TODOS los ids que recibe, sin mirar el estado previo. El DELETE de
-- paradas si excluye entregados, asi que la parada sobrevive — lo que revive
-- es el pedido. El 15/08 volvieron 19 entregas a 'asignado' porque el
-- encargado reabrio "Armar ruta del dia" para meter un pedido que entro tarde.
--
-- CAUSA 4: cancelar un pedido no lo bajaba del camion
-- ---------------------------------------------------
-- `cancelar_pedido_con_stock` no toca `recorrido_pedidos`. Quedan 118 paradas
-- de pedidos cancelados, 115 en rutas en curso: cuentan en total_pedidos y el
-- chofer las ve en el mapa, maneja hasta la puerta y no puede sacarselas de
-- encima. `quitar_pedido_de_recorridos_activos()` ya existia y hacia
-- exactamente esto; solo la llamaba "Volver a pendiente".
--
-- LO QUE ESTA MIGRACION NO TOCA
-- -----------------------------
-- Ni `rendiciones` ni `rendiciones_control`. `crear_rendicion_recorrido` si
-- filtra por `rp.estado_entrega`, pero esta sin uso (1 fila en `rendiciones`,
-- 16 en `rendicion_items`, ningun .rpc() en el front). El flujo real es
-- `confirmar_rendicion` sobre `rendiciones_control`, que calcula desde `pagos`
-- y `pedidos` y no lee `recorrido_pedidos`: los montos de las 19 rendiciones
-- confirmadas afectadas NO estan corrompidos. Lo que estaba mal es lo que se
-- muestra en Recorridos.
--
-- AVISO OPERATIVO
-- ---------------
-- Despues de aplicar esto la pantalla de Recorridos muestra numeros distintos
-- a los que se vieron ayer, incluidos meses pasados. Es el objetivo.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1 · La parada se busca por pedido, no por fecha
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.actualizar_recorrido_entrega()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_recorrido_id BIGINT;
  v_rid          BIGINT;
BEGIN
  -- La parada de ESTA entrega: la del recorrido mas reciente que contenga el
  -- pedido. Sin filtro de fecha ni de estado del recorrido: el guard
  -- `r.fecha = CURRENT_DATE` de la mig 173 dejaba sin registrar el 79% de las
  -- entregas, y CURRENT_DATE es UTC (falla tambien en vivo pasadas las 21 ART).
  SELECT rp.recorrido_id INTO v_recorrido_id
  FROM recorrido_pedidos rp
  JOIN recorridos r ON r.id = rp.recorrido_id
  WHERE rp.pedido_id = NEW.id
  ORDER BY r.fecha DESC, r.created_at DESC
  LIMIT 1;

  IF v_recorrido_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Solo en la transicion a entregado: si no, un cobro posterior pisaria la
  -- hora_entrega real.
  IF NEW.estado = 'entregado' AND OLD.estado IS DISTINCT FROM 'entregado' THEN
    UPDATE recorrido_pedidos
    SET estado_entrega = 'entregado',
        hora_entrega   = NOW()
    WHERE recorrido_id = v_recorrido_id
      AND pedido_id    = NEW.id;
  END IF;

  -- Los contadores se recalculan en TODOS los recorridos que contienen el
  -- pedido: 25 figuran en mas de uno por re-ruteo. Es recalculo, no delta.
  FOR v_rid IN
    SELECT DISTINCT rp.recorrido_id
      FROM recorrido_pedidos rp
     WHERE rp.pedido_id = NEW.id
  LOOP
    UPDATE recorridos r
    SET pedidos_entregados = sub.entregados,
        total_cobrado      = sub.cobrado
    FROM (
      SELECT COUNT(*) FILTER (WHERE p.estado = 'entregado')                        AS entregados,
             COALESCE(SUM(p.monto_pagado) FILTER (WHERE p.estado = 'entregado'), 0) AS cobrado
      FROM recorrido_pedidos rp
      JOIN pedidos p ON p.id = rp.pedido_id
      WHERE rp.recorrido_id = v_rid
    ) sub
    WHERE r.id = v_rid;
  END LOOP;

  RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION public.actualizar_recorrido_entrega() IS
  'Sincroniza la parada del recorrido con el pedido. SECURITY DEFINER a '
  'proposito (mig 173). Desde la mig 180 la parada se busca por pedido_id: el '
  'filtro r.fecha = CURRENT_DATE dejaba sin registrar el 79% de las entregas.';

-- -------------------------------------------------------------------------
-- 2 · Un recalculo idempotente e invocable, que es lo que faltaba
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recalcular_recorrido(p_recorrido_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
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
  --    historial (el insert real), no de now().
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
     AND COALESCE(rp.estado_entrega, 'pendiente') <> 'entregado';
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

  -- c) los cuatro contadores, desde las paradas.
  UPDATE recorridos r
     SET total_pedidos      = sub.cnt,
         total_facturado    = sub.fact,
         pedidos_entregados = sub.entregados,
         total_cobrado      = sub.cobrado
    FROM (
      SELECT COUNT(*)                                                              AS cnt,
             COALESCE(SUM(p.total), 0)                                             AS fact,
             COUNT(*) FILTER (WHERE p.estado = 'entregado')                         AS entregados,
             COALESCE(SUM(p.monto_pagado) FILTER (WHERE p.estado = 'entregado'), 0) AS cobrado
        FROM recorrido_pedidos rp
        JOIN pedidos p ON p.id = rp.pedido_id
       WHERE rp.recorrido_id = p_recorrido_id
    ) sub
   WHERE r.id = p_recorrido_id;

  RETURN jsonb_build_object(
    'success',             true,
    'recorrido_id',        p_recorrido_id,
    'paradas_realineadas', v_realineadas,
    'paradas_revertidas',  v_revertidas
  );
END;
$fn$;

COMMENT ON FUNCTION public.recalcular_recorrido(bigint) IS
  'Reconstruye estado_entrega/hora_entrega de las paradas y los cuatro '
  'contadores del recorrido tomando los pedidos como fuente de verdad. '
  'Idempotente. Existe porque hasta la mig 180 no habia forma de reparar un '
  'contador desalineado.';

REVOKE ALL ON FUNCTION public.recalcular_recorrido(bigint) FROM anon;
GRANT EXECUTE ON FUNCTION public.recalcular_recorrido(bigint) TO authenticated;

-- -------------------------------------------------------------------------
-- 3 · Re-armar la ruta no revive entregas ni cancelados
-- -------------------------------------------------------------------------
-- Se parchea leyendo el catalogo (migrations/ no es 1:1 con prod), exigiendo
-- que el ancla aparezca exactamente una vez: si el cuerpo derivo, la migracion
-- falla en vez de aplicar un parche parcial. Mismo criterio que la mig 178.
DO $mig$
DECLARE
  v_def   text;
  v_ancla CONSTANT text := $a$    UPDATE pedidos
    SET transportista_id = p_transportista_id,
        estado = 'asignado',
        orden_entrega = (v_item->>'orden_entrega')::INTEGER
    WHERE id = (v_item->>'pedido_id')::BIGINT
      AND sucursal_id = v_sucursal;$a$;
  v_nuevo CONSTANT text := $a$    UPDATE pedidos
    SET transportista_id = p_transportista_id,
        estado = 'asignado',
        orden_entrega = (v_item->>'orden_entrega')::INTEGER
    WHERE id = (v_item->>'pedido_id')::BIGINT
      AND sucursal_id = v_sucursal
      -- mig 180: re-armar la ruta no puede devolver a 'asignado' algo que ya
      -- se entrego o se cancelo. La parada se reinserta igual mas abajo, asi
      -- que la entrega hecha sigue figurando en la hoja de ruta.
      AND estado NOT IN ('entregado', 'cancelado', 'anulado');$a$;
  v_veces integer;
BEGIN
  v_def := pg_get_functiondef('public.aplicar_orden_ruta(uuid,jsonb,numeric,integer,jsonb,date)'::regprocedure);

  IF position('mig 180' in v_def) > 0 THEN
    RAISE NOTICE 'mig 180 · aplicar_orden_ruta ya parcheada, se omite';
    RETURN;
  END IF;

  v_veces := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'mig 180 · el ancla de aplicar_orden_ruta aparece % veces (se esperaba 1). El cuerpo derivo; revisa el parche antes de aplicar.', v_veces;
  END IF;

  EXECUTE replace(v_def, v_ancla, v_nuevo);
END;
$mig$;

-- -------------------------------------------------------------------------
-- 4a · Bajar una parada tiene que dejar los contadores del recorrido al dia
-- -------------------------------------------------------------------------
-- `quitar_pedido_de_recorridos_activos` borraba la parada y no tocaba
-- `recorridos`, asi que total_pedidos/total_facturado quedaban contando algo
-- que ya no existe. Le pasaba tambien a su unico caller de hoy ("Volver a
-- pendiente"). Ahora recalcula los recorridos que efectivamente toco.
CREATE OR REPLACE FUNCTION public.quitar_pedido_de_recorridos_activos(p_pedido_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursal  BIGINT := current_sucursal_id();
  v_role      TEXT;
  v_borradas  INT;
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
  WITH borradas AS (
    DELETE FROM recorrido_pedidos rp
     USING recorridos r
     WHERE rp.recorrido_id = r.id
       AND rp.pedido_id    = p_pedido_id
       AND rp.sucursal_id  = v_sucursal
       AND r.estado        = 'en_curso'
    RETURNING rp.recorrido_id
  )
  SELECT array_agg(DISTINCT recorrido_id), count(*)::int
    INTO v_afectados, v_borradas
    FROM borradas;

  v_borradas := COALESCE(v_borradas, 0);

  IF v_afectados IS NOT NULL THEN
    FOREACH v_rid IN ARRAY v_afectados LOOP
      PERFORM public.recalcular_recorrido(v_rid);
    END LOOP;
  END IF;

  RETURN jsonb_build_object('success', true, 'paradas_eliminadas', v_borradas);
END;
$fn$;

COMMENT ON FUNCTION public.quitar_pedido_de_recorridos_activos(bigint) IS
  'Baja un pedido de las rutas en curso y recalcula los contadores de esas '
  'rutas (mig 180: antes borraba la parada y dejaba total_pedidos contandola).';

-- -------------------------------------------------------------------------
-- 4 · Cancelar un pedido lo baja del camion
-- -------------------------------------------------------------------------
DO $mig$
DECLARE
  v_def    text;
  v_decl   CONSTANT text := $a$  v_acting_user uuid;$a$;
  v_decl_n CONSTANT text := $a$  v_acting_user uuid;
  v_quitar jsonb;$a$;
  v_ancla  CONSTANT text := $a$  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)$a$;
  v_nuevo  CONSTANT text := $a$  -- mig 180: la parada de un pedido cancelado no es una parada. Sin esto
  -- quedaban 118 colgadas, 115 en rutas en curso: contaban en total_pedidos y
  -- el chofer las veia en el mapa sin poder sacarselas de encima.
  v_quitar := public.quitar_pedido_de_recorridos_activos(p_pedido_id);
  IF NOT COALESCE((v_quitar->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'No se pudo quitar el pedido de las rutas activas: %',
      COALESCE(v_quitar->>'error', 'error desconocido');
  END IF;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)$a$;
  v_veces integer;
BEGIN
  v_def := pg_get_functiondef('public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure);

  IF position('mig 180' in v_def) > 0 THEN
    RAISE NOTICE 'mig 180 · cancelar_pedido_con_stock ya parcheada, se omite';
    RETURN;
  END IF;

  FOR v_veces IN
    SELECT (length(v_def) - length(replace(v_def, a, ''))) / length(a)
      FROM unnest(ARRAY[v_decl, v_ancla]) a
  LOOP
    IF v_veces <> 1 THEN
      RAISE EXCEPTION 'mig 180 · un ancla de cancelar_pedido_con_stock aparece % veces (se esperaba 1). El cuerpo derivo; revisa el parche antes de aplicar.', v_veces;
    END IF;
  END LOOP;

  v_def := replace(v_def, v_decl,  v_decl_n);
  v_def := replace(v_def, v_ancla, v_nuevo);
  EXECUTE v_def;
END;
$mig$;

-- -------------------------------------------------------------------------
-- 5 · Backfill: 1.455 paradas, 118 cancelados, 86 recorridos
-- -------------------------------------------------------------------------
DO $backfill$
DECLARE
  v_cancelados   INT;
  v_r            RECORD;
  v_res          jsonb;
  v_realineadas  INT := 0;
  v_revertidas   INT := 0;
  v_recorridos   INT := 0;
BEGIN
  -- Primero las paradas de cancelados: si no, entran en el recalculo de
  -- total_pedidos como una parada mas.
  DELETE FROM recorrido_pedidos rp
   USING pedidos p
   WHERE p.id = rp.pedido_id
     AND p.estado IN ('cancelado', 'anulado');
  GET DIAGNOSTICS v_cancelados = ROW_COUNT;

  FOR v_r IN SELECT id FROM recorridos ORDER BY id LOOP
    v_res         := public.recalcular_recorrido(v_r.id);
    v_realineadas := v_realineadas + COALESCE((v_res->>'paradas_realineadas')::int, 0);
    v_revertidas  := v_revertidas  + COALESCE((v_res->>'paradas_revertidas')::int, 0);
    v_recorridos  := v_recorridos + 1;
  END LOOP;

  RAISE NOTICE 'mig 180 · backfill: % paradas de cancelados eliminadas, % paradas realineadas, % revertidas, % recorridos recalculados',
    v_cancelados, v_realineadas, v_revertidas, v_recorridos;
END;
$backfill$;

-- -------------------------------------------------------------------------
-- 6 · Los tres invariantes, para que el gate diario avise si vuelve a pasar
-- -------------------------------------------------------------------------
DO $mig$
DECLARE
  v_def   text;
  v_ancla CONSTANT text := $a$ AND creado_por IS NULL))
  )$a$;
  v_nuevo CONSTANT text := $a$ AND creado_por IS NULL)),
    -- ===== Rutas (mig 180) =====
    ('RUTA-A','high','paradas de pedidos entregados que quedaron sin marcar',
      (SELECT count(*) FROM recorrido_pedidos rp JOIN pedidos p ON p.id=rp.pedido_id
        WHERE p.estado='entregado' AND COALESCE(rp.estado_entrega,'pendiente')<>'entregado')),
    ('RUTA-B','high','recorridos con pedidos_entregados/total_cobrado distintos del recalculo',
      (SELECT count(*) FROM recorridos r
         LEFT JOIN LATERAL (
           SELECT COUNT(*) FILTER (WHERE p.estado='entregado') AS ent,
                  COALESCE(SUM(p.monto_pagado) FILTER (WHERE p.estado='entregado'),0) AS cob
             FROM recorrido_pedidos rp JOIN pedidos p ON p.id=rp.pedido_id
            WHERE rp.recorrido_id=r.id) s ON TRUE
        WHERE r.pedidos_entregados IS DISTINCT FROM s.ent
           OR COALESCE(r.total_cobrado,0) IS DISTINCT FROM COALESCE(s.cob,0))),
    -- Acotado a 'en_curso' para que el check mida exactamente lo que el codigo
    -- garantiza: quitar_pedido_de_recorridos_activos() solo baja paradas de
    -- rutas en curso. Una ruta cerrada conserva su historia.
    ('RUTA-C','medium','paradas de pedidos cancelados/anulados en una ruta en curso',
      (SELECT count(*) FROM recorrido_pedidos rp
         JOIN pedidos p    ON p.id = rp.pedido_id
         JOIN recorridos r ON r.id = rp.recorrido_id
        WHERE p.estado IN ('cancelado','anulado') AND r.estado='en_curso'))
  )$a$;
  v_veces integer;
BEGIN
  v_def := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);

  IF position('mig 180' in v_def) > 0 THEN
    RAISE NOTICE 'mig 180 · checks RUTA-* ya presentes, se omite';
    RETURN;
  END IF;

  v_veces := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'mig 180 · el ancla de auditoria_integridad aparece % veces (se esperaba 1). El cuerpo derivo; revisa el parche antes de aplicar.', v_veces;
  END IF;

  EXECUTE replace(v_def, v_ancla, v_nuevo);
END;
$mig$;

COMMIT;

-- -------------------------------------------------------------------------
-- Verificacion (esperado: los tres en 0)
--
--   SELECT c->>'id', c->>'violaciones'
--     FROM jsonb_array_elements(auditoria_integridad()->'checks') c
--    WHERE c->>'id' LIKE 'RUTA-%';
--
-- Contra-prueba del trigger (lo que antes no pasaba): marcar entregado un
-- pedido de una ruta de ayer y verificar que la parada y los contadores se
-- mueven.
-- -------------------------------------------------------------------------

-- 439 · Las rutas y los pagos se bloquean siempre en el mismo orden (#1375).
--
-- QUÉ PASABA
--   Dos caminos tomaban las mismas filas en orden distinto y Postgres abortaba a uno con
--   40P01. No rompía datos: la transacción volvía atrás y alguien veía un error. El arnés
--   de #1288 lo midió en las rutas (C7a, C7c, C7d, C7e, C7f) y en la foto de la rendición
--   (C6b, C6d).
--   · Rutas: aplicar_orden_ruta actualizaba los pedidos en el orden del JSON y las masivas
--     en el orden físico. Cada UPDATE llega a recorridos por
--     trigger_actualizar_recorrido_entrega, así que el reorden tenía [Y, ruta] y pedía X
--     mientras una entrega tenía X y pedía la ruta.
--   · Pagos: la foto bloquea por id; el recorte, de fecha DESC, id DESC; y
--     cambiar_cliente_pedido, en orden físico.
--
-- QUÉ CAMBIA (sólo el orden de los locks)
--   · Rutas: pedidos por id y después recorridos por id, todos antes de la primera
--     escritura. Es lo que ya hace una entrega o un cobro suelto: pedido, ruta, y recién
--     después el cliente (los triggers AFTER de pedidos corren por nombre). Incluye los
--     pedidos que salen de la ruta y las otras rutas de cada pedido, que el trigger
--     recalcula: sin eso dos masivas sin pedidos en común se cruzan en los recorridos.
--   · Pagos: por id, el orden de la foto. La foto no cambia: bajarla a fecha DESC abría
--     cruces nuevos con aplicar_credito_cliente (fecha ASC, id ASC) y con el UPDATE de
--     cancelar_pedido_con_stock (físico). desafectar_sobrepago_pedido bloquea antes de su
--     bucle, y el bucle sigue recortando desde el pago más nuevo.
--     _pagos_excedente_a_favor no cambia: lo llama sólo cambiar_cliente_pedido, y sus
--     pagos ya llegan bloqueados.
--
-- QUÉ NO CAMBIA
--   Qué hace cada función: filtros, recortes, resultados. El corte ultimo_pago_id (#1292)
--   se apoya en que la foto tiene todos los locks al leer max(id), no en el orden.
--   Las firmas, los EXECUTE y actualizar_recorrido_entrega.
--
-- Ensayo: scripts/test-orden-locks-1375.sql, y C6 y C7 del arnés (scripts/concurrencia).
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
      ('public.aplicar_orden_ruta(uuid,jsonb,numeric,integer,jsonb,date)', '11642f6233e1b17dd60b514bd065bdad'),
      ('public.marcar_entregas_masivo(bigint[],uuid,date)', 'b0d36676bcb3a4bf24b952f0eb674f7d'),
      ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)', '8f0367f4ed13f10143c827e3873b170f'),
      ('public.desafectar_sobrepago_pedido(bigint)', '5ae2f4897b068859b749fa56d9430398'),
      ('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', '7986e58056ad1c9162c8df9b618f0de4')
    ) AS t(firma, hash)
  LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure) <> r.hash THEN
      RAISE EXCEPTION '% cambió en prod (md5 %): rehacer el parche sobre el cuerpo vigente',
        r.firma, (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure);
    END IF;
  END LOOP;
END
$premisas$;

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
  v_bloquear BIGINT[];
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

  -- #1375: una ruta bloquea sus pedidos por id y después sus recorridos por id,
  -- todos antes de tocar nada: es el orden de una entrega o un cobro, que toman
  -- el pedido y, por trigger_actualizar_recorrido_entrega, sus rutas. Van los que
  -- entran y los que salen, y las otras rutas de cada uno, que el trigger y el
  -- paso (a) de abajo recalculan. NO KEY UPDATE es el lock que toma el UPDATE: uno
  -- más fuerte frenaría las FKs que hoy no esperan.
  v_bloquear := v_nuevos || ARRAY(SELECT rp.pedido_id
                                    FROM recorrido_pedidos rp
                                   WHERE rp.recorrido_id = v_recorrido_id);

  PERFORM 1
     FROM pedidos
    WHERE id = ANY(v_bloquear)
      AND sucursal_id = v_sucursal
    ORDER BY id
      FOR NO KEY UPDATE;

  PERFORM 1
     FROM recorridos
    WHERE id = v_recorrido_id
       OR id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                  WHERE rp.pedido_id = ANY(v_bloquear))
    ORDER BY id
      FOR NO KEY UPDATE;

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

CREATE OR REPLACE FUNCTION public.marcar_entregas_masivo(p_pedido_ids bigint[], p_transportista_id uuid, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id BIGINT;
  v_affected INTEGER;
  v_fecha_ts TIMESTAMPTZ;
  v_cerrado RECORD; -- #1318
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo encargado o admin pueden marcar entregas masivas'
      USING ERRCODE = '42501';
  END IF;

  IF p_pedido_ids IS NULL OR array_length(p_pedido_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  -- #1318 (REN-1): entregar con la fecha de un día ya controlado reabría ese
  -- control como efecto secundario (trg_pedidos_anular_control lo borra con su
  -- foto). Un día cerrado se reabre a propósito, desde la rendición. Mira los
  -- dos lados que borra el trigger: el día nuevo del chofer nuevo, y el día que
  -- ya tuviera anotado el pedido.
  SELECT x.chofer, x.dia INTO v_cerrado
    FROM (SELECT p_transportista_id AS chofer, p_fecha AS dia
          UNION ALL
          SELECT p.transportista_id, (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
            FROM pedidos p
           WHERE p.id = ANY(p_pedido_ids)
             AND p.sucursal_id = v_sucursal_id
             AND COALESCE(p.estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
             AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB'
             AND p.canal IS DISTINCT FROM 'cambio'
             AND p.fecha_entrega IS NOT NULL) x
   WHERE x.chofer IS NOT NULL
     AND public.control_rendicion_cerrado(x.chofer, v_sucursal_id, x.dia)
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'La rendición del % de % ya fue controlada: esta entrega la reabriría. Elegí otra fecha, o reabrí primero el control de ese día.',
      to_char(v_cerrado.dia, 'DD/MM/YYYY'),
      COALESCE((SELECT nombre FROM perfiles WHERE id = v_cerrado.chofer), 'ese chofer')
      USING ERRCODE = '42501';
  END IF;

  v_fecha_ts := (p_fecha::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz;

  -- #1375: el orden de aplicar_orden_ruta, pedidos por id y después recorridos
  -- por id. Sin esto el UPDATE sigue el orden físico y los triggers por fila
  -- toman las rutas en el orden de sus filas.
  PERFORM 1
     FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
    ORDER BY id
      FOR NO KEY UPDATE;

  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                  WHERE rp.pedido_id = ANY(p_pedido_ids))
    ORDER BY id
      FOR NO KEY UPDATE;

  UPDATE pedidos
     SET estado = 'entregado',
         fecha_entrega = v_fecha_ts,
         transportista_id = p_transportista_id,
         updated_at = now()
   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id
     -- mig 181: el unico guard vivia en el filtro de la query del front, y la
     -- ventana es todo el tiempo que el modal queda abierto (sin realtime sobre
     -- pedidos ni revalidacion al confirmar).
     AND COALESCE(estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
     AND COALESCE(tipo_factura, 'ZZ') <> 'VB'  -- mig 3XA
     -- #1318: la comanda de un canje se entrega desde el pedido, que aplica el
     -- cambio (aplicar_cambio_de_parada) antes de cerrarla.
     AND canal IS DISTINCT FROM 'cambio';

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RETURN v_affected;
END;
$function$;

CREATE OR REPLACE FUNCTION public.marcar_entrega_y_pago_masivo_impl(p_pedido_ids bigint[], p_transportista_id uuid, p_forma_pago text, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id BIGINT;
  v_affected INTEGER;
  v_pedido RECORD;
  v_rol TEXT;
  v_fecha_ts TIMESTAMPTZ;
  v_cerrado RECORD; -- #1318
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo encargado o admin pueden marcar entrega y pago masivos'
      USING ERRCODE = '42501';
  END IF;

  -- #1249: antes no se validaba; ademas escribe pedidos.forma_pago.
  p_forma_pago := public._forma_pago_de_cobro(p_forma_pago, true);

  -- Mismo gate de rendición que marcar_pagos_masivo (esta RPC registra pagos)
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
  IF v_rol = 'encargado' THEN
    -- mig 230: la base corre en UTC. Comparar contra CURRENT_DATE entre las
    -- 21:00 y las 24:00 ART rechazaba justo la fecha correcta.
    IF p_fecha <> (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date THEN
      RAISE EXCEPTION 'Encargado solo puede registrar pagos con fecha de hoy'
        USING ERRCODE = '42501';
    END IF;
    IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id) THEN
      RAISE EXCEPTION 'Rendicion ya cerrada para esta fecha. Pedi a un admin.'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  IF p_pedido_ids IS NULL OR array_length(p_pedido_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  -- #1318 (REN-1): el mismo corte que marcar_entregas_masivo. Va antes del
  -- cobro: si la entrega no entra, el cobro tampoco.
  SELECT x.chofer, x.dia INTO v_cerrado
    FROM (SELECT p_transportista_id AS chofer, p_fecha AS dia
          UNION ALL
          SELECT p.transportista_id, (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
            FROM pedidos p
           WHERE p.id = ANY(p_pedido_ids)
             AND p.sucursal_id = v_sucursal_id
             AND COALESCE(p.estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
             AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB'
             AND p.canal IS DISTINCT FROM 'cambio'
             AND p.fecha_entrega IS NOT NULL) x
   WHERE x.chofer IS NOT NULL
     AND public.control_rendicion_cerrado(x.chofer, v_sucursal_id, x.dia)
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'La rendición del % de % ya fue controlada: esta entrega la reabriría. Elegí otra fecha, o reabrí primero el control de ese día.',
      to_char(v_cerrado.dia, 'DD/MM/YYYY'),
      COALESCE((SELECT nombre FROM perfiles WHERE id = v_cerrado.chofer), 'ese chofer')
      USING ERRCODE = '42501';
  END IF;

  v_fecha_ts := (p_fecha::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz;

  -- #1375: el orden de aplicar_orden_ruta, pedidos por id y después recorridos
  -- por id, antes del primer pago: cada INSERT llega a la ruta por el trigger de
  -- monto_pagado, y el FOR UPDATE del bucle no alcanza a los que ya estan pagados,
  -- que el UPDATE de abajo tambien toca. Va FOR UPDATE, el del bucle: tomar uno
  -- menor y subirlo despues puede cruzarse con una FK.
  PERFORM 1
     FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
    ORDER BY id
      FOR UPDATE;

  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                  WHERE rp.pedido_id = ANY(p_pedido_ids))
    ORDER BY id
      FOR NO KEY UPDATE;

  -- 1) Registrar pago por el saldo pendiente (solo pedidos NO pagados)
  FOR v_pedido IN
    SELECT id, cliente_id, total, COALESCE(monto_pagado, 0) AS ya_pagado
    FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
      AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
      -- #1318 (PED-3): un entregado no se vuelve a entregar, como en la 181.
      AND COALESCE(estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
      AND canal IS DISTINCT FROM 'cambio'
      AND total > COALESCE(monto_pagado, 0)
      AND COALESCE(tipo_factura, 'ZZ') <> 'VB'  -- mig 3XA
    ORDER BY id
    FOR UPDATE
  LOOP
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
    VALUES (
      v_pedido.cliente_id,
      v_pedido.id,
      v_pedido.total - v_pedido.ya_pagado,
      p_forma_pago,
      p_fecha,
      auth.uid(),
      v_sucursal_id
    );
  END LOOP;

  -- 2) Entregar + saldar en un solo UPDATE (transportista_id SE asigna)
  -- mig 181: no revivir un pedido cancelado como entregado y pagado.
  UPDATE pedidos
     SET estado = 'entregado',
         fecha_entrega = v_fecha_ts,
         transportista_id = p_transportista_id,
         -- mig 230: ya NO se escribe monto_pagado = total, igual que la 181 en
         -- marcar_pagos_masivo_impl. El INSERT en pagos de arriba dispara
         -- recalcular_monto_pagado_pedido, que lo deriva de SUM(pagos). Este
         -- UPDATE alcanza a TODOS los ids del lote -- tambien los que el bucle
         -- salteo por ya estar pagados -- asi que fijarlo a mano tapaba un
         -- cobro concurrente y dejaba el pedido saldado con dos pagos encima.
         forma_pago = p_forma_pago,
         updated_at = now()
   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id
     -- #1318 (PED-3): un entregado no se vuelve a entregar: le pisaba el
     -- chofer y la fecha, y el trigger le borraba el control del día viejo.
     AND COALESCE(estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
     AND COALESCE(tipo_factura, 'ZZ') <> 'VB'  -- mig 3XA
     -- #1318: la comanda de un canje se entrega desde el pedido, que aplica el
     -- cambio (aplicar_cambio_de_parada) antes de cerrarla.
     AND canal IS DISTINCT FROM 'cambio';

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RETURN v_affected;
END;
$function$;

CREATE OR REPLACE FUNCTION public.desafectar_sobrepago_pedido(p_pedido_id bigint)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_pedido     RECORD;
  v_pago       RECORD;
  v_excedente  numeric;
  v_quitar     numeric;
  v_quitado    numeric := 0;
  v_nota       text;
  v_guc        text;
  v_marca      text;
BEGIN
  SELECT id, total, COALESCE(monto_pagado, 0) AS pagado, estado
    INTO v_pedido
    FROM pedidos
   WHERE id = p_pedido_id;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  IF v_pedido.estado IN ('cancelado', 'anulado') THEN
    RETURN 0;
  END IF;

  v_excedente := v_pedido.pagado - v_pedido.total;
  IF v_excedente <= 0.005 THEN
    RETURN 0;
  END IF;

  -- #1375: los pagos se bloquean por id, como la foto de la rendicion, los
  -- creditos y los UPDATE por pedido. El orden del bucle de abajo es de negocio y
  -- no cambia; si bloqueara el, se cruzaria con la foto con dos pagos del dia.
  PERFORM 1
     FROM pagos
    WHERE pedido_id = p_pedido_id
    ORDER BY id
      FOR UPDATE;

  -- Se recorta desde el pago mas nuevo: el excedente es lo ultimo que se cargo.
  FOR v_pago IN
    SELECT id, monto, cliente_id, forma_pago, fecha, referencia, usuario_id,
           sucursal_id, nota_credito_id, pago_origen_id, a_cuenta
      FROM pagos
     WHERE pedido_id = p_pedido_id
     ORDER BY fecha DESC, id DESC
     FOR UPDATE
  LOOP
    EXIT WHEN v_excedente <= 0.005;

    v_quitar := LEAST(v_pago.monto, v_excedente);

    -- #1329: un pago a cuenta es plata que entro, no un cobro por el total de la
    -- boleta: lo que sobra queda a favor del cliente, y la caja del dia no se
    -- mueve (por eso va con el escape del guard, como la reimputacion). Decision
    -- del dueño. El credito de una NC sigue por su rama de abajo, y un adelanto de
    -- sueldo no es plata que entro: se recorta.
    IF v_pago.nota_credito_id IS NULL
       AND COALESCE(v_pago.forma_pago, '') <> 'adelanto_sueldo'
       AND (v_pago.a_cuenta OR v_pago.pago_origen_id IS NOT NULL) THEN
      v_marca := ' [baja de total del pedido #' || p_pedido_id || '] [saldo a favor]';
      v_guc := current_setting('app.reimputacion_pagos', true);
      PERFORM set_config('app.reimputacion_pagos', 'on', true);

      IF v_quitar >= v_pago.monto - 0.005 THEN
        UPDATE pagos
           SET pedido_id = NULL,
               notas = trim(COALESCE(notas, '') || v_marca)
         WHERE id = v_pago.id;
        v_quitar := v_pago.monto;
      ELSE
        UPDATE pagos SET monto = monto - v_quitar WHERE id = v_pago.id;

        INSERT INTO pagos (
          cliente_id, pedido_id, monto, forma_pago, fecha,
          referencia, notas, usuario_id, sucursal_id, pago_origen_id, a_cuenta
        )
        SELECT cliente_id, NULL, v_quitar, forma_pago, fecha, referencia,
               trim(COALESCE(notas, '') || v_marca),
               usuario_id, sucursal_id, COALESCE(pago_origen_id, id), true
          FROM pagos
         WHERE id = v_pago.id;
      END IF;

      PERFORM set_config('app.reimputacion_pagos', COALESCE(v_guc, ''), true);

      v_excedente := v_excedente - v_quitar;
      v_quitado   := v_quitado + v_quitar;
      CONTINUE;
    END IF;
    v_nota := ' [ajustado -' || trim(to_char(v_quitar, 'FM999999990.00')) ||
              ' por baja de total del pedido ' || p_pedido_id || ']';

    IF v_pago.monto - v_quitar > 0.005 THEN
      UPDATE pagos
         SET monto = monto - v_quitar,
             notas = trim(COALESCE(notas, '') || v_nota)
       WHERE id = v_pago.id;
    ELSE
      -- CHECK pagos_monto_positivo (#1246): el pago entero se borra en vez de
      -- pasar por monto 0. El UPDATE sin cambio de monto es a proposito: pasa
      -- por la misma guarda de caja que el recorte (guard_pago_fecha_cerrada es
      -- BEFORE UPDATE OF monto y el DELETE no la dispara), asi que borrarlo
      -- entero con la caja cerrada sigue rechazado igual que antes.
      UPDATE pagos
         SET monto = monto,
             notas = trim(COALESCE(notas, '') || v_nota)
       WHERE id = v_pago.id;
      DELETE FROM pagos WHERE id = v_pago.id;
    END IF;

    -- mig 276 (#833): un credito de NC no es plata que se devuelve, es un
    -- documento. Lo que la boleta ya no necesita vuelve a saldo a favor con el
    -- mismo documento (pago sin pedido), en vez de evaporarse. La proxima
    -- imputacion (aplicar_credito_cliente, que el trigger de reconciliacion
    -- llama enseguida) lo aplica a otra boleta, y la NC vuelve a ser anulable
    -- por ese pedazo.
    IF v_pago.nota_credito_id IS NOT NULL THEN
      INSERT INTO pagos (
        cliente_id, pedido_id, monto, forma_pago, fecha,
        referencia, notas, usuario_id, sucursal_id, nota_credito_id, pago_origen_id
      ) VALUES (
        v_pago.cliente_id, NULL, v_quitar, v_pago.forma_pago, v_pago.fecha,
        v_pago.referencia,
        'Nota de credito #' || v_pago.nota_credito_id || ': vuelve por baja de total del pedido '
          || p_pedido_id || ' [saldo a favor]',
        v_pago.usuario_id, v_pago.sucursal_id, v_pago.nota_credito_id,
        COALESCE(v_pago.pago_origen_id, v_pago.id)
      );
    END IF;

    v_excedente := v_excedente - v_quitar;
    v_quitado   := v_quitado + v_quitar;
  END LOOP;

  RETURN v_quitado;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cambiar_cliente_pedido(p_pedido_id bigint, p_nuevo_cliente_id bigint, p_usuario_id uuid, p_items jsonb, p_total numeric, p_total_neto numeric DEFAULT NULL::numeric, p_total_iva numeric DEFAULT 0, p_motivo text DEFAULT 'Cambio de cliente'::text, p_destino_pagos text DEFAULT 'pedido_nuevo'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal     BIGINT := current_sucursal_id();
  v_acting       UUID := auth.uid();
  v_role         TEXT;
  v_pedido       RECORD;
  v_prev_role    TEXT;
  v_preventista  UUID := NULL;
  v_preventista_fallback BOOLEAN := false;
  v_cancel       JSONB;
  v_crear        JSONB;
  v_nuevo_id     BIGINT;
  -- envio_historial_y_rol (#1231): el cargo con que nacio el pedido nuevo.
  v_cargo_nuevo  NUMERIC;
  v_estado_nuevo TEXT;
  -- #1248: lo que el pedido nuevo cobro de mas y quedo a favor del cliente nuevo.
  v_excedente    NUMERIC := 0;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay sucursal activa');
  END IF;

  IF p_usuario_id IS DISTINCT FROM v_acting THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_role FROM perfiles WHERE id = v_acting;
  IF v_role IS NULL OR v_role <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin puede cambiar el cliente de un pedido');
  END IF;

  IF p_destino_pagos IS NULL OR p_destino_pagos NOT IN ('pedido_nuevo', 'cliente_original') THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Destino de los pagos invalido: ' || COALESCE(p_destino_pagos, 'NULL')
      || '. Tiene que ser pedido_nuevo o cliente_original.');
  END IF;

  -- La reatribucion no es una venta nueva: el pedido ya cumplio (o no) el
  -- minimo cuando se creo. Ver mig 205.
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  -- mig 389 (#1220): la reatribucion conserva el cargo que el pedido ya tenia.
  PERFORM set_config('app.cargo_envio_forzado',
    COALESCE((SELECT cargo_envio::text FROM pedidos WHERE id = p_pedido_id), '0'), true);
  -- cargo_1_base: y su estado (un no_aplica o un bonificado no renacen gratis).
  PERFORM set_config('app.cargo_envio_estado_forzado',
    COALESCE((SELECT cargo_envio_estado FROM pedidos WHERE id = p_pedido_id), ''), true);

  -- Con 'pedido_nuevo' los pagos NO se desimputan al cancelar el viejo: mas
  -- abajo se reapuntan al pedido nuevo, para que el cobro viaje con la venta.
  -- Sin esto, la desimputacion de la mig 235 se los lleva antes y el UPDATE de
  -- mas abajo no encuentra nada. Con 'cliente_original' esa desimputacion es
  -- justo lo que se quiere: el cobro queda a favor del cliente que pago.
  IF p_destino_pagos = 'pedido_nuevo' THEN
    PERFORM set_config('app.cancelacion_conserva_pagos', '1', true);
  END IF;


  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'El pedido nuevo no tiene items');
  END IF;

  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado');
  END IF;

  IF COALESCE(v_pedido.tipo_factura, 'ZZ') = 'VB' THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Un vale blanco no cambia de cliente: cancelalo y cargalo de nuevo al cliente correcto');
  END IF;

  IF v_pedido.estado IN ('entregado', 'cancelado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede cambiar el cliente de un pedido ' || v_pedido.estado);
  END IF;

  IF p_nuevo_cliente_id = v_pedido.cliente_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'El cliente nuevo es el mismo que el actual');
  END IF;

  -- mig 276 (#833): con 'pedido_nuevo' los pagos se reapuntan al cliente nuevo.
  -- Un credito de NC es del cliente de la NC: no viaja. Con 'cliente_original'
  -- no viaja nada, y el credito vuelve a saldo a favor de su cliente.
  IF p_destino_pagos = 'pedido_nuevo'
     AND EXISTS (SELECT 1 FROM pagos WHERE pedido_id = p_pedido_id AND nota_credito_id IS NOT NULL) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El pedido esta pagado en parte con credito de la nota de credito #'
      || (SELECT min(nota_credito_id) FROM pagos WHERE pedido_id = p_pedido_id AND nota_credito_id IS NOT NULL)
      || ', que es de este cliente: no se puede pasar a otro. Elegi que los pagos queden a favor del cliente original, o cancelalo y carga el pedido nuevo.');
  END IF;

  PERFORM 1 FROM clientes WHERE id = p_nuevo_cliente_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'El cliente nuevo no existe en esta sucursal');
  END IF;

  IF v_pedido.usuario_id IS DISTINCT FROM p_usuario_id THEN
    SELECT p.rol INTO v_prev_role
    FROM perfiles p
    WHERE p.id = v_pedido.usuario_id
      AND p.activo = true
      AND EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = p.id AND us.sucursal_id = v_sucursal);
    IF v_prev_role IN ('admin', 'preventista') THEN
      v_preventista := v_pedido.usuario_id;
    ELSE
      v_preventista_fallback := true;
    END IF;
  END IF;

  v_cancel := cancelar_pedido_con_stock(p_pedido_id, p_motivo, p_usuario_id, 'cambio_de_cliente');
  IF NOT COALESCE((v_cancel->>'success')::boolean, false) THEN
    RETURN v_cancel;
  END IF;

  PERFORM quitar_pedido_de_recorridos_activos(p_pedido_id);

  -- #1301: los combos del pedido nuevo se miden contra la foto de este, no
  -- contra la definicion vigente, y el nuevo hereda esa foto.
  PERFORM set_config('app.combo_foto_pedido', p_pedido_id::text, true);

  v_crear := crear_pedido_completo(
    p_nuevo_cliente_id,
    p_total,
    p_usuario_id,
    p_items,
    v_pedido.notas,
    v_pedido.forma_pago,
    'pendiente',
    v_pedido.fecha,
    v_pedido.tipo_factura,
    p_total_neto,
    COALESCE(p_total_iva, 0),
    v_pedido.fecha_entrega_programada,
    v_preventista
  );
  IF NOT COALESCE((v_crear->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'No se pudo crear el pedido nuevo: %',
      COALESCE(v_crear->>'errores', v_crear->>'error', 'error desconocido');
  END IF;
  v_nuevo_id := (v_crear->>'pedido_id')::bigint;
  PERFORM set_config('app.combo_foto_pedido', '', true);

  IF p_destino_pagos = 'pedido_nuevo' THEN
    -- #1375: por id, como la foto de la rendicion. El UPDATE solo sigue el orden
    -- fisico, y un pago ya editado queda detras de los mas nuevos.
    PERFORM 1
       FROM pagos
      WHERE pedido_id = p_pedido_id
        AND sucursal_id = v_sucursal
      ORDER BY id
        FOR UPDATE;

    UPDATE pagos
       SET pedido_id = v_nuevo_id,
           cliente_id = p_nuevo_cliente_id
     WHERE pedido_id = p_pedido_id
       AND sucursal_id = v_sucursal;

    -- #1248 (COB-3): si el total nuevo es menor, lo cobrado de mas pasa a saldo
    -- a favor del cliente nuevo y se aplica a sus otras boletas. Sin esto
    -- quedaba atrapado en la boleta: zzz_pedidos_reconciliar_pagos es OF total
    -- y aca solo cambia monto_pagado (trampa 6).
    v_excedente := public._pagos_excedente_a_favor(v_nuevo_id);
    IF v_excedente > 0 THEN
      PERFORM public.aplicar_credito_cliente(p_nuevo_cliente_id, v_sucursal);
    END IF;
  END IF;

  UPDATE pedidos
     SET motivo_cancelacion = COALESCE(motivo_cancelacion, p_motivo) || ' -> pedido #' || v_nuevo_id
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (
    v_nuevo_id,
    v_acting,
    'cliente_id',
    v_pedido.cliente_id::text,
    p_nuevo_cliente_id::text || ' (cambio de cliente desde pedido #' || p_pedido_id || ')',
    v_sucursal
  );

  -- envio_historial_y_rol (#1231): la reatribucion conserva cargo y estado;
  -- si el pedido nuevo nacio con otros (p. ej. sin productos: cargo 0,
  -- 'gratis'), queda anotado en el nuevo, contra lo que tenia el viejo.
  SELECT cargo_envio, cargo_envio_estado INTO v_cargo_nuevo, v_estado_nuevo
    FROM pedidos WHERE id = v_nuevo_id AND sucursal_id = v_sucursal;
  IF COALESCE(v_pedido.cargo_envio, 0) IS DISTINCT FROM COALESCE(v_cargo_nuevo, 0) THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (v_nuevo_id, v_acting, 'cargo_envio', round(COALESCE(v_pedido.cargo_envio, 0), 2)::TEXT,
            round(COALESCE(v_cargo_nuevo, 0), 2)::TEXT, v_sucursal);
  END IF;
  IF v_pedido.cargo_envio_estado IS DISTINCT FROM v_estado_nuevo THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (v_nuevo_id, v_acting, 'cargo_envio_estado', v_pedido.cargo_envio_estado, v_estado_nuevo, v_sucursal);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'nuevo_pedido_id', v_nuevo_id,
    'pedido_cancelado_id', p_pedido_id,
    'preventista_fallback', v_preventista_fallback,
    'destino_pagos', p_destino_pagos,
    'excedente_a_favor', v_excedente
  );
END;
$function$;

COMMIT;

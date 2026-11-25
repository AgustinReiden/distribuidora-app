-- =========================================================================
-- NNN · RUTAS, PARADAS, FECHAS Y CANJES (ola 3, tarjeta T3 de #1677)
--
-- Puntos Rut-B3, B4, B5, B6, B8, B10, B11, B13 y B14 de #1554 y permisos-B1
-- (= 1564-b9). Ensayo: scripts/test-ola3-rutas-paradas-canjes.sql (sin esta
-- migración falla en B13 B4 B5 B11 B6 P1 B3 B8 B10 B14; con ella, ENSAYO OK).
-- Se aplica en LF, en una sola transacción o sentencia por sentencia, y
-- reaplicarla aborta en las premisas (md5 de los cuerpos vivos de la 547).
--
-- 1 · Rut-B3: cerrar_recorridos_vencidos cerraba la ruta a las 23:59 de la
--     zona de la sesión (UTC en prod = 20:59 de Argentina). Ahora a las 23:59
--     del día argentino de la ruta.
-- 2 · Rut-B4: aplicar_cambio_de_parada autorizaba a cualquier chofer con una
--     parada de la historia del canje (una ruta cerrada, un 'reasignado'). Ahora
--     el chofer necesita la parada viva (ruta suya en curso, sin entregar ni
--     reasignar) y ser el chofer del canje. Admin y encargado, como antes.
-- 3 · Rut-B5: actualizar_recorrido_entrega (el trigger de la entrega) marcaba
--     entregada la parada de A cuando una masiva entregaba el pedido a nombre
--     de B. Ahora marca la parada de una ruta del que entrega; la de otro chofer
--     queda 'reasignado' y deja de contar en esa ruta.
-- 4 · Rut-B6: aplicar_orden_ruta aceptaba cualquier fecha. Ahora la de la
--     entrega programada: de hoy a 60 días adelante (1559-b6, D21).
-- 5 · Rut-B8: registrar_cambio_producto recibe p_clave (uuid, DEFAULT NULL) con
--     el mecanismo de altas_por_clave (operación 'cambio_producto'): la misma
--     clave con lo mismo devuelve el canje del primer intento; con otra cosa,
--     22023. Sin clave (un PWA viejo), como antes. La firma vieja se DROPea en
--     esta misma migración: no quedan dos sobrecargas (PGRST203), y PostgREST
--     resuelve los siete parámetros por nombre de un bundle viejo contra la
--     nueva. Única DDL de tabla existente: el CHECK de altas_por_clave (su LOCK
--     va al principio, NOWAIT).
-- 6 · Rut-B10: crear_recorrido se borra. Sin EXECUTE para la app desde la 314,
--     y nada la llama: ni src/, ni supabase/functions/, ni scripts/ (sólo dos
--     ensayos, que se corrigen en el mismo PR), ni otra función, vista o policy.
-- 7 · Rut-B11: _recorrido_contadores.total_cobrado sumaba monto_pagado, con el
--     saldo a favor y la nota de crédito aplicados. Ahora la plata: los pagos
--     dinerarios de la boleta sin de_saldo_a_favor ni nota_credito_id. Se
--     recalcula la columna de las rutas que ya existen (RUTA-B lo exige).
-- 8 · Rut-B13: crear_pedido_cambio_en_ruta llena creado_por.
-- 9 · Rut-B14 (la mitad de SQL): el cupo por usuario de la edge function
--     optimizar-ruta. Tabla optimizar_ruta_cupo_uso (sólo de server) y RPC
--     optimizar_ruta_consumir_cupo(p_max_por_minuto, p_max_por_dia), el mismo
--     mecanismo que bot_consumir_cupo (mig 296), pero por usuario y con la
--     sesión del que llama (la edge ya la usa para preguntar el rol).
-- 10 · permisos-B1: recalcular_recorrido acota la ruta a la sucursal activa.
--
-- No toca (son de otra tarjeta): marcar_no_entregado, _pedido_a_pendiente,
-- cambiar_transportista_recorrido, quitar_pedido_de_recorridos_activos,
-- recorridos_estado_transicion, pedidos_registrar_armado ni
-- pedidos_proteger_columnas.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- La única DDL de una tabla que ya existe (el CHECK de altas_por_clave): su lock
-- primero, sin esperar. Si un alta la tiene tomada, falla al instante y se reintenta.
LOCK TABLE public.altas_por_clave IN ACCESS EXCLUSIVE MODE NOWAIT;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos de producción en la 547.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.cerrar_recorridos_vencidos(bigint)', 'c173f542ac27b09e154b6c8c28439a2a'),
    ('public.aplicar_cambio_de_parada(bigint,uuid,date)', 'bd549595eab0d84e0dbd00b01e18dcdd'),
    ('public.actualizar_recorrido_entrega()', '86fdd50a205c4c25c4d701fbac5276df'),
    ('public.aplicar_orden_ruta(uuid,jsonb,numeric,integer,jsonb,date)', '8023195a7078920efc376f2ed675c125'),
    ('public.registrar_cambio_producto(integer,bigint,integer,bigint,integer,text,text)', 'b5ab06b83108608241b6775c55358759'),
    ('public.crear_recorrido(uuid,jsonb,numeric,integer)', '607e7a05ff0e29553674a8725f33b204'),
    ('public._recorrido_contadores(bigint)', 'f82f8e32b56c5c03f998d54ea1a4f1f8'),
    ('public.crear_pedido_cambio_en_ruta(integer,bigint,integer,bigint,integer,text,text)', '42b01dbb1bb1fc38a42926cd9c776ed7'),
    ('public.recalcular_recorrido(bigint)', '02fb88f3e4ca09188833d260c0bc502c')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
         AND proname = 'registrar_cambio_producto') <> 1 THEN
    RAISE EXCEPTION 'mig NNN · registrar_cambio_producto tiene más de una firma: rehacer sobre lo vigente';
  END IF;
  SELECT pg_get_constraintdef(oid) INTO v FROM pg_constraint
   WHERE conrelid = 'public.altas_por_clave'::regclass AND conname = 'altas_por_clave_operacion_check';
  IF v IS DISTINCT FROM $c$CHECK ((operacion = ANY (ARRAY['condicion_mayorista'::text, 'promocion'::text, 'cliente'::text, 'gasto'::text, 'empleado'::text])))$c$ THEN
    RAISE EXCEPTION 'mig NNN · el CHECK de altas_por_clave no es el de la 542 (%): rehacer sobre lo vigente', v;
  END IF;
  IF to_regclass('public.optimizar_ruta_cupo_uso') IS NOT NULL
     OR to_regproc('public.optimizar_ruta_consumir_cupo') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · el cupo de optimizar-ruta ya existe: rehacer sobre lo vigente';
  END IF;
END
$premisas$;

-- =========================================================================
-- 1 · Rut-B3: cerrar_recorridos_vencidos
-- =========================================================================
CREATE OR REPLACE FUNCTION public.cerrar_recorridos_vencidos(p_sucursal_id bigint DEFAULT NULL::bigint)
 RETURNS TABLE(cerrados integer, con_pendientes integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cerrados INT := 0;
  v_pendientes INT := 0;
BEGIN
  -- #1048: `current_user` adentro de una DEFINER es el dueño, nunca
  -- 'authenticated'. Lo que distingue a una sesión de la app es auth.uid().
  IF auth.uid() IS NOT NULL AND NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo un admin o encargado puede cerrar recorridos vencidos'
      USING ERRCODE = '42501';
  END IF;

  WITH vencidos AS (
    SELECT r.id,
           EXISTS (
             SELECT 1
             FROM recorrido_pedidos rp
             JOIN pedidos p ON p.id = rp.pedido_id
             WHERE rp.recorrido_id = r.id
               AND p.estado = 'asignado'
           ) AS tiene_pendientes
    FROM recorridos r
    WHERE r.estado = 'en_curso'
      -- #1056: el día argentino. CURRENT_DATE es UTC: pasadas las 21:00
      -- cerraba la ruta que el chofer está haciendo.
      AND r.fecha < (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
      AND (p_sucursal_id IS NULL OR r.sucursal_id = p_sucursal_id)
  ),
  cerrados_ahora AS (
    UPDATE recorridos r
       SET estado = 'completado',
           -- mig NNN (Rut-B3, T3 de la ola 3): las 23:59 del día argentino de la ruta. Con
           -- `(fecha + TIME '23:59')::timestamptz` la hora se leía en la zona de la sesión
           -- (UTC en prod) y la ruta quedaba cerrada a las 20:59 de Argentina.
           completed_at = COALESCE(r.completed_at,
                                   (r.fecha + TIME '23:59') AT TIME ZONE 'America/Argentina/Buenos_Aires')
      FROM vencidos v
     WHERE v.id = r.id
       AND NOT v.tiene_pendientes
    RETURNING r.id
  )
  SELECT
    (SELECT count(*) FROM cerrados_ahora),
    (SELECT count(*) FROM vencidos WHERE tiene_pendientes)
  INTO v_cerrados, v_pendientes;

  RETURN QUERY SELECT v_cerrados, v_pendientes;
END;
$function$;

-- =========================================================================
-- 2 · Rut-B4: aplicar_cambio_de_parada
-- =========================================================================
CREATE OR REPLACE FUNCTION public.aplicar_cambio_de_parada(p_pedido_id bigint, p_transportista_id uuid DEFAULT NULL::uuid, p_fecha date DEFAULT NULL::date)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_rc RECORD;
  v_user UUID := auth.uid();
  v_suc BIGINT := public.current_sucursal_id();
  v_cambio_id BIGINT;
  v_autorizado BOOLEAN;
  v_ped RECORD;
  v_ahora RECORD;
  v_chofer UUID;
  v_dia DATE;
  v_motivo_fecha TEXT;  -- mig NNN (R1, #1603)
BEGIN
  SELECT * INTO v_rc FROM recorrido_cambios WHERE pedido_id = p_pedido_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No hay detalle de cambio para el pedido %', p_pedido_id;
  END IF;

  IF v_rc.aplicado_at IS NOT NULL THEN
    RETURN v_rc.cambio_producto_id;
  END IF;

  -- #1343: el canje es de la sucursal activa (current_sucursal_id ya exige que el que
  -- llama sea de ella): sin esto, un encargado de otra sucursal lo aplicaba por id.
  -- Y es una comanda de canje viva: ni un pedido común ni una baja.
  SELECT canal, estado, transportista_id, sucursal_id INTO v_ped FROM pedidos WHERE id = p_pedido_id;
  IF v_suc IS NULL OR v_ped.sucursal_id IS DISTINCT FROM v_suc THEN
    RAISE EXCEPTION 'El canje #% no es de la sucursal activa: cambiá a su sucursal para completarlo.',
      p_pedido_id USING ERRCODE = '42501';
  END IF;
  IF v_ped.canal IS DISTINCT FROM 'cambio' THEN
    RAISE EXCEPTION 'El pedido #% no es un canje: no tiene cambio de producto que aplicar.', p_pedido_id;
  END IF;
  IF v_ped.estado IN ('cancelado', 'anulado') THEN
    RAISE EXCEPTION 'El canje #% está %: no se aplica el cambio.', p_pedido_id, v_ped.estado;
  END IF;

  -- mig NNN (Rut-B4, T3 de la ola 3): el chofer, sólo con la parada VIVA del canje: en una
  -- ruta suya en curso, sin entregar ni reasignar, y siendo hoy el chofer del canje (la entrega
  -- que viene sale a su nombre). Antes alcanzaba cualquier parada de su historia (una ruta
  -- cerrada, un 'reasignado'): el chofer de ayer movía el stock del canje que hoy reparte otro.
  v_autorizado := public.es_encargado_o_admin()
    OR (v_user IS NOT NULL
        AND v_ped.transportista_id IS NOT DISTINCT FROM v_user
        AND EXISTS (
          SELECT 1
          FROM recorrido_pedidos rp
          JOIN recorridos r ON r.id = rp.recorrido_id
          WHERE rp.pedido_id = p_pedido_id
            AND r.transportista_id = v_user
            AND r.estado = 'en_curso'
            AND rp.estado_entrega IN ('pendiente', 'no_entregado')
        ));
  IF NOT v_autorizado THEN
    RAISE EXCEPTION 'No autorizado para aplicar el cambio';
  END IF;

  -- #1343: el cambio se aplica sólo si la entrega que viene después puede entrar. El día
  -- es el de la entrega: el chofer y la fecha que elige el front, o los del pedido y hoy.
  -- El chofer elegido tiene que poder repartir en la sucursal, la misma regla que
  -- pedidos_entrega_con_chofer: si no, el cambio se aplicaba y la entrega daba 23514.
  IF p_transportista_id IS NOT NULL AND NOT (
       EXISTS (SELECT 1 FROM usuario_sucursales us
                WHERE us.usuario_id = p_transportista_id AND us.sucursal_id = v_suc)
       AND public._actua_como_transportista(p_transportista_id, v_suc)) THEN
    RAISE EXCEPTION 'El transportista elegido no es chofer de esta sucursal: no se aplicó el cambio.' USING ERRCODE = '42501';
  END IF;
  v_chofer := COALESCE(p_transportista_id, v_ped.transportista_id);
  v_dia := COALESCE(p_fecha, public._tablero_hoy());
  -- mig NNN (R1, #1603): la fecha de la entrega que viene tiene que entrar en su rango
  -- (GTO-15, #1597). Sin esto el canje movía el stock, el PATCH de la entrega daba 22023 y la
  -- comanda quedaba sin entregar con el cambio aplicado. La misma regla y la misma condición
  -- que pedidos_proteger_columnas: sólo si el día argentino cambia, con el piso del admin para
  -- el admin y el de la política para el resto. Antes de tomar nada.
  IF ((SELECT pe.fecha_entrega FROM pedidos pe WHERE pe.id = p_pedido_id)
        AT TIME ZONE 'America/Argentina/Buenos_Aires')::date IS DISTINCT FROM v_dia THEN
    v_motivo_fecha := public._fecha_entrega_fuera_de_rango(v_dia, v_ped.sucursal_id, public.es_admin());
    IF v_motivo_fecha IS NOT NULL THEN
      RAISE EXCEPTION '%', v_motivo_fecha USING ERRCODE = '22023';
    END IF;
  END IF;
  IF v_chofer IS NOT NULL THEN
    -- La rendición antes que el pedido (439). El try no espera: si se está confirmando,
    -- que se reintente con el control ya decidido. Mismos estados, try y errores que
    -- anular_control_por_cambio_fecha_entrega (443).
    IF NOT pg_try_advisory_xact_lock_shared(public._rendicion_clave(v_chofer, v_dia, v_ped.sucursal_id)) THEN
      RAISE EXCEPTION 'La rendición del % de ese transportista se está controlando o editando en este momento: volvé a intentar en unos segundos.',
        to_char(v_dia, 'DD/MM/YYYY') USING ERRCODE = '40001';
    END IF;
    IF EXISTS (SELECT 1 FROM rendiciones_control
                WHERE transportista_id = v_chofer AND sucursal_id = v_ped.sucursal_id
                  AND fecha = v_dia AND estado IN ('confirmada', 'resuelta')) THEN
      RAISE EXCEPTION 'La rendición del % de ese transportista ya fue controlada: no se aplicó el cambio. Un encargado o administrador tiene que reabrirla primero desde Rendiciones.',
        to_char(v_dia, 'DD/MM/YYYY') USING ERRCODE = '42501';
    END IF;
  END IF;

  -- El pedido, y con él quieto se vuelve a mirar: dos llamadas a la vez aplicaban el
  -- cambio dos veces. La rendición mirada tiene que ser la de la entrega que viene:
  --   · el chofer del pedido no cambió desde que se leyó (si cambió, tomar su rendición
  --     recién ahora invertiría el orden);
  --   · y si el front manda un chofer y el pedido ya tiene otro, la pantalla está vieja:
  --     la entrega saldría a nombre del del pedido. El front manda uno distinto del del
  --     pedido sólo cuando el pedido no tiene chofer y se elige al confirmar
  --     (necesitaElegirChofer), y ese caso pasa.
  PERFORM 1 FROM pedidos WHERE id = p_pedido_id FOR UPDATE;
  SELECT estado, transportista_id INTO v_ahora FROM pedidos WHERE id = p_pedido_id;
  SELECT * INTO v_rc FROM recorrido_cambios WHERE pedido_id = p_pedido_id;
  IF v_rc.aplicado_at IS NOT NULL THEN
    RETURN v_rc.cambio_producto_id;
  END IF;
  IF v_ahora.estado IN ('cancelado', 'anulado') THEN
    RAISE EXCEPTION 'El canje #% está %: no se aplica el cambio.', p_pedido_id, v_ahora.estado;
  END IF;
  IF v_ahora.transportista_id IS DISTINCT FROM v_ped.transportista_id
     OR (p_transportista_id IS NOT NULL AND v_ahora.transportista_id IS NOT NULL
         AND v_ahora.transportista_id <> p_transportista_id) THEN
    RAISE EXCEPTION 'El canje #% tiene otro transportista que el elegido: actualizá la pantalla y volvé a intentar.',
      p_pedido_id USING ERRCODE = '40001';
  END IF;

  v_cambio_id := public._aplicar_cambio_producto(
    v_rc.cliente_id,
    v_rc.producto_devuelto_id, v_rc.cantidad_devuelta,
    v_rc.producto_entregado_id, v_rc.cantidad_entregada,
    v_rc.observaciones, v_rc.sucursal_id, v_user, COALESCE(v_rc.motivo,'erroneo')
  );

  UPDATE recorrido_cambios
     SET aplicado_at = NOW(), cambio_producto_id = v_cambio_id
   WHERE pedido_id = p_pedido_id;

  RETURN v_cambio_id;
END;
$function$;

-- =========================================================================
-- 3 · Rut-B5: actualizar_recorrido_entrega (trigger AFTER UPDATE de pedidos)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.actualizar_recorrido_entrega()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
    -- mig NNN (Rut-B5, T3 de la ola 3): la parada que se marca es la de una ruta de QUIEN
    -- ENTREGA (NEW.transportista_id). Una masiva a nombre de B de un pedido que vivía en la
    -- ruta de A marcaba entregada la parada de A, que A no hizo, y se la contaba a A. Ahora esa
    -- parada sale de la ruta de A como 'reasignado' (historia: el pedido se entregó en otra
    -- ruta, como lo entienden _recorrido_contadores y RUTA-A) y se busca la del que entrega.
    -- Las rutas ya están tomadas (arriba): las paradas se escriben con ellas quietas. Un
    -- entregado sin chofer no pasa (pedidos_entrega_con_chofer); si pasara, como antes.
    IF NEW.transportista_id IS NOT NULL THEN
      UPDATE recorrido_pedidos rp
         SET estado_entrega = 'reasignado'
        FROM recorridos r
       WHERE r.id = rp.recorrido_id
         AND rp.pedido_id = NEW.id
         AND rp.estado_entrega = 'pendiente'
         AND r.transportista_id IS DISTINCT FROM NEW.transportista_id;

      v_parada := NULL;
      v_recorrido_id := NULL;
      SELECT rp.id, rp.recorrido_id
        INTO v_parada, v_recorrido_id
      FROM recorrido_pedidos rp
      JOIN recorridos r ON r.id = rp.recorrido_id
      WHERE rp.pedido_id = NEW.id
        AND rp.estado_entrega IN ('pendiente', 'entregado')
        AND r.transportista_id = NEW.transportista_id
      ORDER BY (r.estado = 'en_curso') DESC, r.fecha DESC, r.created_at DESC, r.id DESC
      LIMIT 1;
    END IF;

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
        -- mig NNN (Rut-B5): también acá, sólo una ruta del que entrega.
        AND (NEW.transportista_id IS NULL OR r.transportista_id = NEW.transportista_id)
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

-- =========================================================================
-- 4 · Rut-B6: aplicar_orden_ruta
-- =========================================================================
CREATE OR REPLACE FUNCTION public.aplicar_orden_ruta(p_transportista_id uuid, p_pedidos jsonb, p_distancia numeric DEFAULT NULL::numeric, p_duracion integer DEFAULT NULL::integer, p_polylines jsonb DEFAULT NULL::jsonb, p_fecha date DEFAULT NULL::date)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
  v_motivo_fecha TEXT;  -- mig NNN (Rut-B6)
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

  -- #1548 (RUT-2): la ruta sale a nombre de quien reparte en esta sucursal: activo, de la
  -- sucursal y con el rol de chofer. Es la regla de la entrega (pedidos_entrega_con_chofer).
  IF p_transportista_id IS NULL OR NOT public._actua_como_transportista(p_transportista_id, v_sucursal) THEN
    RAISE EXCEPTION 'La ruta no puede salir a nombre de %: no es un chofer activo de esta sucursal.',
      COALESCE((SELECT nombre FROM perfiles WHERE id = p_transportista_id), 'ese usuario')
      USING ERRCODE = '42501';
  END IF;

  -- mig NNN (Rut-B6, T3 de la ola 3): la fecha de la ruta es un día de reparto que viene, así
  -- que rige la regla de la entrega programada (1559-b6, decisión del dueño D21): de hoy a 60
  -- días adelante, para todos. Sin esto entraba cualquier fecha (una ruta de 2016 o de 2099).
  -- La pantalla ya ofrece desde hoy (el min del input de ModalGestionRutas).
  v_motivo_fecha := public._fecha_entrega_programada_fuera_de_rango(v_fecha, public._tablero_hoy());
  IF v_motivo_fecha IS NOT NULL THEN
    RAISE EXCEPTION '%', v_motivo_fecha USING ERRCODE = '22023';
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

-- =========================================================================
-- 5 · Rut-B8: registrar_cambio_producto con clave (altas_por_clave)
-- =========================================================================
ALTER TABLE public.altas_por_clave DROP CONSTRAINT altas_por_clave_operacion_check;
ALTER TABLE public.altas_por_clave ADD CONSTRAINT altas_por_clave_operacion_check
  CHECK (operacion = ANY (ARRAY['condicion_mayorista'::text, 'promocion'::text, 'cliente'::text,
                                'gasto'::text, 'empleado'::text, 'cambio_producto'::text]));

DROP FUNCTION public.registrar_cambio_producto(integer, bigint, integer, bigint, integer, text, text);

CREATE FUNCTION public.registrar_cambio_producto(
  p_cliente_id integer,
  p_producto_devuelto_id bigint,
  p_cantidad_devuelta integer,
  p_producto_entregado_id bigint,
  p_cantidad_entregada integer,
  p_observaciones text DEFAULT NULL::text,
  p_motivo text DEFAULT 'erroneo'::text,
  p_clave uuid DEFAULT NULL::uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sucursal BIGINT := public.current_sucursal_id();
  v_user UUID := auth.uid();
  v_contenido TEXT;
  v_previa public.altas_por_clave%ROWTYPE;
  v_id BIGINT;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'Sin sucursal activa';
  END IF;
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- mig NNN (Rut-B8, T3 de la ola 3): el canje con la clave del formulario (el patrón de
  -- C4b, altas_por_clave, como guardar_gasto). Un doble toque, o el reintento de una
  -- respuesta perdida, manda la misma clave con lo mismo y recibe el canje del primer
  -- intento, sin mover el stock otra vez. La misma clave con otra cosa, de otra operación,
  -- de otro usuario o de otra sucursal: 22023. Sin clave (un PWA de antes), como siempre.
  -- Dos intentos a la vez con la misma clave: el segundo espera en la PK de altas_por_clave
  -- a que el primero confirme (y ve su canje) o se deshaga (y lo hace él), antes de tomar
  -- ningún producto.
  IF p_clave IS NOT NULL THEN
    v_contenido := md5(jsonb_build_object(
      'cliente', p_cliente_id,
      'devuelto', p_producto_devuelto_id, 'cantidad_devuelta', p_cantidad_devuelta,
      'entregado', p_producto_entregado_id, 'cantidad_entregada', p_cantidad_entregada,
      'observaciones', p_observaciones, 'motivo', COALESCE(p_motivo, 'erroneo'))::text);
    INSERT INTO altas_por_clave (clave, operacion, usuario_id, sucursal_id, contenido)
    VALUES (p_clave, 'cambio_producto', v_user, v_sucursal, v_contenido)
    ON CONFLICT (clave) DO NOTHING;
    IF NOT FOUND THEN
      SELECT * INTO v_previa FROM altas_por_clave WHERE clave = p_clave;
      IF v_previa.operacion <> 'cambio_producto' OR v_previa.usuario_id IS DISTINCT FROM v_user
         OR v_previa.sucursal_id <> v_sucursal THEN
        RAISE EXCEPTION 'Esta clave ya se usó para otra operación: recargá la página e intentá de nuevo.'
          USING ERRCODE = '22023';
      END IF;
      IF v_previa.contenido <> v_contenido THEN
        RAISE EXCEPTION 'Este cambio de productos ya se registró con el intento anterior y lo que mandaste ahora es distinto: cerrá esta ventana y revisá los canjes del cliente antes de cargar otro.'
          USING ERRCODE = '22023';
      END IF;
      IF v_previa.entidad_id IS NULL
         OR NOT EXISTS (SELECT 1 FROM cambios_productos WHERE id = v_previa.entidad_id) THEN
        RAISE EXCEPTION 'Este cambio de productos ya se había registrado con el intento anterior y no se encuentra: revisá los canjes del cliente antes de cargarlo de nuevo.'
          USING ERRCODE = '22023';
      END IF;
      RETURN v_previa.entidad_id;
    END IF;
  END IF;

  -- #1319: un canje es operar, y con un cliente dado de baja no se opera.
  IF EXISTS (SELECT 1 FROM clientes WHERE id = p_cliente_id AND NOT activo) THEN
    RAISE EXCEPTION 'El cliente está dado de baja: reactivalo desde Clientes para registrarle un cambio de producto.'
      USING ERRCODE = 'P0001';
  END IF;

  v_id := public._aplicar_cambio_producto(
    p_cliente_id, p_producto_devuelto_id, p_cantidad_devuelta,
    p_producto_entregado_id, p_cantidad_entregada, p_observaciones,
    v_sucursal, v_user, COALESCE(p_motivo,'erroneo')
  );

  IF p_clave IS NOT NULL THEN
    UPDATE altas_por_clave SET entidad_id = v_id WHERE clave = p_clave;
  END IF;

  RETURN v_id;
END;
$function$;

-- Los permisos de la firma vieja: authenticated y service_role, nada para anon.
REVOKE ALL ON FUNCTION public.registrar_cambio_producto(integer, bigint, integer, bigint, integer, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_cambio_producto(integer, bigint, integer, bigint, integer, text, text, uuid) TO authenticated, service_role;

-- =========================================================================
-- 6 · Rut-B10: crear_recorrido, código muerto
-- =========================================================================
DROP FUNCTION public.crear_recorrido(uuid, jsonb, numeric, integer);

-- =========================================================================
-- 7 · Rut-B11: _recorrido_contadores cuenta sólo la plata cobrada
-- =========================================================================
CREATE OR REPLACE FUNCTION public._recorrido_contadores(p_recorrido_id bigint)
 RETURNS TABLE(total_pedidos integer, total_facturado numeric, pedidos_entregados integer, total_cobrado numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- Sólo las paradas vivas: el pedido no entregado acá, o que pasó a otra
  -- ruta, no es una parada que la ruta tenga que hacer, facturar ni cobrar
  -- (#1313). Así "pendientes = total - entregados" (bot, /recorridos) cierra.
  -- mig NNN (Rut-B11, T3 de la ola 3): lo cobrado es la plata que entró por la boleta, no
  -- monto_pagado: sin el saldo a favor aplicado (de_saldo_a_favor, #1469; es de quien lo
  -- cobró antes, como en _rendicion_pagos, #1492), sin la nota de crédito (nota_credito_id) y
  -- sin lo que no es plata (formas_pago().dineraria: el adelanto de sueldo). Con monto_pagado,
  -- una boleta de 1000 cobrada 700 en la calle y 300 con saldo a favor sumaba 1000.
  SELECT (COUNT(*) FILTER (WHERE rp.estado_entrega IN ('pendiente', 'entregado')))::integer,
         COALESCE(SUM(p.total) FILTER (
           WHERE rp.estado_entrega IN ('pendiente', 'entregado')
             AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB'), 0),
         (COUNT(*) FILTER (
           WHERE rp.estado_entrega IN ('pendiente', 'entregado')
             AND p.estado = 'entregado'))::integer,
         COALESCE(SUM(c.plata) FILTER (
           WHERE rp.estado_entrega IN ('pendiente', 'entregado')
             AND p.estado = 'entregado'
             AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB'), 0)
    FROM recorrido_pedidos rp
    JOIN pedidos p ON p.id = rp.pedido_id
    LEFT JOIN LATERAL (
      SELECT SUM(pg.monto) AS plata
        FROM pagos pg
        JOIN public.formas_pago() f ON f.forma = pg.forma_pago::text
       WHERE pg.pedido_id = p.id
         AND p.estado = 'entregado'
         AND f.dineraria
         AND NOT pg.de_saldo_a_favor
         AND pg.nota_credito_id IS NULL
    ) c ON true
   WHERE rp.recorrido_id = p_recorrido_id;
$function$;

-- Las rutas que ya existen, con lo cobrado de la regla nueva (RUTA-B compara la
-- columna con la función). Sólo total_cobrado: no dispara trg_recorridos_estado
-- (UPDATE OF estado, completed_at). Una por una y por id, sólo las que cambian: el
-- orden de las rutas de una entrega (#1375), sin tomar ninguna que no se escriba.
DO $b11$
DECLARE
  v_id bigint;
  v_n  integer := 0;
BEGIN
  FOR v_id IN
    SELECT x.id
      FROM public.recorridos x
     CROSS JOIN LATERAL public._recorrido_contadores(x.id) c
     WHERE COALESCE(x.total_cobrado, 0) IS DISTINCT FROM c.total_cobrado
     ORDER BY x.id
  LOOP
    UPDATE public.recorridos r
       SET total_cobrado = c.total_cobrado
      FROM public._recorrido_contadores(v_id) c
     WHERE r.id = v_id;
    v_n := v_n + 1;
  END LOOP;
  RAISE NOTICE 'mig NNN · Rut-B11: % ruta(s) con lo cobrado recalculado', v_n;
END
$b11$;

-- =========================================================================
-- 8 · Rut-B13: crear_pedido_cambio_en_ruta llena creado_por
-- =========================================================================
CREATE OR REPLACE FUNCTION public.crear_pedido_cambio_en_ruta(p_cliente_id integer, p_producto_devuelto_id bigint, p_cantidad_devuelta integer, p_producto_entregado_id bigint, p_cantidad_entregada integer, p_observaciones text DEFAULT NULL::text, p_motivo text DEFAULT 'erroneo'::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sucursal BIGINT := public.current_sucursal_id();
  v_user UUID := auth.uid();
  v_nombre_devuelto TEXT;
  v_nombre_entregado TEXT;
  v_pedido_id BIGINT;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'Sin sucursal activa';
  END IF;
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;
  IF p_cantidad_devuelta <= 0 OR p_cantidad_entregada <= 0 THEN
    RAISE EXCEPTION 'Las cantidades deben ser mayores a 0';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM clientes WHERE id = p_cliente_id AND sucursal_id = v_sucursal
  ) THEN
    RAISE EXCEPTION 'Cliente no encontrado en la sucursal';
  END IF;
  -- #1343: un canje es operar, y con un cliente dado de baja no se opera (#1319).
  IF EXISTS (SELECT 1 FROM clientes WHERE id = p_cliente_id AND NOT activo) THEN
    RAISE EXCEPTION 'El cliente está dado de baja: reactivalo desde Clientes para registrarle un cambio de producto.'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT nombre INTO v_nombre_devuelto FROM productos
   WHERE id = p_producto_devuelto_id AND sucursal_id = v_sucursal;
  IF v_nombre_devuelto IS NULL THEN
    RAISE EXCEPTION 'Producto a devolver no encontrado';
  END IF;
  SELECT nombre INTO v_nombre_entregado FROM productos
   WHERE id = p_producto_entregado_id AND sucursal_id = v_sucursal;
  IF v_nombre_entregado IS NULL THEN
    RAISE EXCEPTION 'Producto a entregar no encontrado';
  END IF;

  -- mig NNN (Rut-B13, T3 de la ola 3): con creado_por, como todo pedido (quién lo cargó).
  INSERT INTO pedidos (
    cliente_id, fecha, estado, total, monto_pagado, estado_pago,
    canal, usuario_id, creado_por, sucursal_id
  ) VALUES (
    p_cliente_id, public._tablero_hoy(), 'pendiente', 0, 0, 'pagado',
    'cambio', v_user, v_user, v_sucursal
  ) RETURNING id INTO v_pedido_id;

  INSERT INTO recorrido_cambios (
    pedido_id, cliente_id,
    producto_devuelto_id, producto_devuelto_nombre, cantidad_devuelta,
    producto_entregado_id, producto_entregado_nombre, cantidad_entregada,
    observaciones, sucursal_id, motivo
  ) VALUES (
    v_pedido_id, p_cliente_id,
    p_producto_devuelto_id, v_nombre_devuelto, p_cantidad_devuelta,
    p_producto_entregado_id, v_nombre_entregado, p_cantidad_entregada,
    p_observaciones, v_sucursal, COALESCE(p_motivo,'erroneo')
  );

  RETURN v_pedido_id;
END;
$function$;

-- =========================================================================
-- 9 · Rut-B14: el cupo por usuario de optimizar-ruta
-- =========================================================================
CREATE TABLE public.optimizar_ruta_cupo_uso (
  usuario_id    uuid        PRIMARY KEY,
  minuto_inicio timestamptz NOT NULL,
  conteo_minuto integer     NOT NULL CHECK (conteo_minuto >= 0),
  dia           date        NOT NULL,
  conteo_dia    integer     NOT NULL CHECK (conteo_dia >= 0)
);

COMMENT ON TABLE public.optimizar_ruta_cupo_uso IS
  'Rut-B14 (ola 3, T3 de #1677): cuántas veces usó cada usuario la edge function optimizar-ruta en el minuto y en el día argentino en curso. Cada llamada es una consulta facturable a Google. Una fila por usuario (se pisa, no crece). La escribe sólo optimizar_ruta_consumir_cupo; sólo de server: RLS sin policies y sin grants para anon ni authenticated. El mismo mecanismo que bot_cupo_uso (mig 296), por usuario en vez de por chat.';

ALTER TABLE public.optimizar_ruta_cupo_uso ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.optimizar_ruta_cupo_uso FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.optimizar_ruta_consumir_cupo(p_max_por_minuto integer, p_max_por_dia integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid    uuid        := auth.uid();
  v_minuto timestamptz := date_trunc('minute', now());
  v_dia    date        := public._tablero_hoy();
  v_min    integer;
  v_dia_n  integer;
BEGIN
  -- Rut-B14 (ola 3, T3 de #1677): la edge function optimizar-ruta la llama con la sesión
  -- del que pide la ruta, después de preguntarle el rol y antes de tocar Google. Los topes
  -- los pone la edge (constantes técnicas, como el cupo del bot). Un usuario que la llame
  -- directo sólo gasta su propio cupo. El rol es el de la edge: chofer (base o extra en la
  -- sucursal activa), encargado o admin; un desactivado no tiene ninguno (#1474).
  IF v_uid IS NULL OR NOT (public.es_transportista() OR public.es_encargado_o_admin()) THEN
    RAISE EXCEPTION 'Se requiere rol transportista, encargado o admin para optimizar rutas'
      USING ERRCODE = '42501';
  END IF;
  IF p_max_por_minuto IS NULL OR p_max_por_dia IS NULL OR p_max_por_minuto < 1 OR p_max_por_dia < 1 THEN
    RAISE EXCEPTION 'Los topes del cupo tienen que ser números positivos' USING ERRCODE = '22023';
  END IF;

  INSERT INTO optimizar_ruta_cupo_uso AS c (usuario_id, minuto_inicio, conteo_minuto, dia, conteo_dia)
  VALUES (v_uid, v_minuto, 1, v_dia, 1)
  ON CONFLICT (usuario_id) DO UPDATE
     SET conteo_minuto = CASE WHEN c.minuto_inicio = v_minuto THEN c.conteo_minuto + 1 ELSE 1 END,
         minuto_inicio = v_minuto,
         conteo_dia    = CASE WHEN c.dia = v_dia THEN c.conteo_dia + 1 ELSE 1 END,
         dia           = v_dia
  RETURNING c.conteo_minuto, c.conteo_dia INTO v_min, v_dia_n;

  IF v_dia_n > p_max_por_dia THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'por_dia', 'conteo', v_dia_n);
  END IF;
  IF v_min > p_max_por_minuto THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'por_minuto', 'conteo', v_min);
  END IF;
  RETURN jsonb_build_object('ok', true, 'conteo_dia', v_dia_n);
END;
$function$;

REVOKE ALL ON FUNCTION public.optimizar_ruta_consumir_cupo(integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.optimizar_ruta_consumir_cupo(integer, integer) TO authenticated, service_role;

-- =========================================================================
-- 10 · permisos-B1: recalcular_recorrido acota la sucursal
-- =========================================================================
CREATE OR REPLACE FUNCTION public.recalcular_recorrido(p_recorrido_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

  -- mig NNN (permisos-B1 = 1564-b9, T3 de la ola 3): la ruta es de la sucursal activa.
  -- Sin esto un encargado de la sucursal 1 recalculaba por id una ruta de la 2 y le volvía a
  -- pendiente una parada entregada (paso b). Una ruta que no existe dice lo mismo (no es un
  -- oráculo de ids). Sin sesión (migración, service_role), como antes.
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM recorridos
        WHERE id = p_recorrido_id
          AND sucursal_id = public.current_sucursal_id()) THEN
    RAISE EXCEPTION 'La ruta #% no es de la sucursal activa: cambiá a su sucursal para recalcularla.',
      p_recorrido_id USING ERRCODE = '42501';
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

-- ---------------------------------------------------------------------------
-- Poscondiciones
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  v text;
BEGIN
  -- Cada función cambiada: el arreglo está, el search_path termina en pg_temp, y los
  -- permisos son los de antes (api = authenticated la ejecuta; anon, nunca).
  FOR r IN SELECT * FROM (VALUES
      ('public.cerrar_recorridos_vencidos(bigint)', 'Rut-B3', false),
      ('public.aplicar_cambio_de_parada(bigint,uuid,date)', 'Rut-B4', true),
      ('public.actualizar_recorrido_entrega()', 'Rut-B5', false),
      ('public.aplicar_orden_ruta(uuid,jsonb,numeric,integer,jsonb,date)', 'Rut-B6', true),
      ('public.registrar_cambio_producto(integer,bigint,integer,bigint,integer,text,text,uuid)', 'Rut-B8', true),
      ('public._recorrido_contadores(bigint)', 'Rut-B11', false),
      ('public.crear_pedido_cambio_en_ruta(integer,bigint,integer,bigint,integer,text,text)', 'Rut-B13', true),
      ('public.optimizar_ruta_consumir_cupo(integer,integer)', 'Rut-B14', true),
      ('public.recalcular_recorrido(bigint)', 'permisos-B1', true)
    ) AS t(f, marca, api) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no quedó', r.f;
    END IF;
    SELECT prosrc INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF strpos(v, r.marca) = 0 THEN
      RAISE EXCEPTION 'mig NNN · % no tiene el arreglo (%)', r.f, r.marca;
    END IF;
    IF (SELECT proconfig FROM pg_proc WHERE oid = r.f::regprocedure) IS DISTINCT FROM ARRAY['search_path=public, pg_temp'] THEN
      RAISE EXCEPTION 'mig NNN · el search_path de % no es public, pg_temp', r.f;
    END IF;
    IF has_function_privilege('anon', r.f, 'EXECUTE')
       OR has_function_privilege('authenticated', r.f, 'EXECUTE') IS DISTINCT FROM r.api
       OR NOT has_function_privilege('service_role', r.f, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig NNN · los permisos de % no son los esperados', r.f;
    END IF;
  END LOOP;
  -- Los cuerpos cambiaron (no se reaplicó lo viejo).
  FOR r IN SELECT * FROM (VALUES
      ('public.cerrar_recorridos_vencidos(bigint)', 'c173f542ac27b09e154b6c8c28439a2a'),
      ('public.aplicar_cambio_de_parada(bigint,uuid,date)', 'bd549595eab0d84e0dbd00b01e18dcdd'),
      ('public.actualizar_recorrido_entrega()', '86fdd50a205c4c25c4d701fbac5276df'),
      ('public.aplicar_orden_ruta(uuid,jsonb,numeric,integer,jsonb,date)', '8023195a7078920efc376f2ed675c125'),
      ('public._recorrido_contadores(bigint)', 'f82f8e32b56c5c03f998d54ea1a4f1f8'),
      ('public.crear_pedido_cambio_en_ruta(integer,bigint,integer,bigint,integer,text,text)', '42b01dbb1bb1fc38a42926cd9c776ed7'),
      ('public.recalcular_recorrido(bigint)', '02fb88f3e4ca09188833d260c0bc502c')
    ) AS t(f, h) LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.f::regprocedure) = r.h THEN
      RAISE EXCEPTION 'mig NNN · % quedó como estaba', r.f;
    END IF;
  END LOOP;
  -- Una sola firma de registrar_cambio_producto (sin PGRST203) y crear_recorrido borrada.
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
         AND proname = 'registrar_cambio_producto') <> 1 THEN
    RAISE EXCEPTION 'mig NNN · registrar_cambio_producto quedó con más de una firma';
  END IF;
  IF to_regproc('public.crear_recorrido') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · crear_recorrido sigue existiendo';
  END IF;
  -- El trigger de la entrega sigue colgado de pedidos como antes.
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgrelid = 'public.pedidos'::regclass AND tgname = 'trigger_actualizar_recorrido_entrega'
                    AND tgfoid = 'public.actualizar_recorrido_entrega()'::regprocedure AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'mig NNN · trigger_actualizar_recorrido_entrega no quedó';
  END IF;
  -- RUTA-B: ninguna ruta con lo cobrado distinto de la función.
  IF EXISTS (SELECT 1 FROM public.recorridos x
               CROSS JOIN LATERAL public._recorrido_contadores(x.id) c
              WHERE x.pedidos_entregados IS DISTINCT FROM c.pedidos_entregados
                 OR COALESCE(x.total_cobrado, 0) IS DISTINCT FROM c.total_cobrado) THEN
    RAISE EXCEPTION 'mig NNN · quedan rutas con los contadores distintos de _recorrido_contadores (RUTA-B)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.altas_por_clave'::regclass AND conname = 'altas_por_clave_operacion_check'
                    AND pg_get_constraintdef(oid) LIKE '%''cambio_producto''::text%') THEN
    RAISE EXCEPTION 'mig NNN · el CHECK de altas_por_clave no quedó con cambio_producto';
  END IF;
  -- La tabla del cupo: RLS y sin grants para la API.
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.optimizar_ruta_cupo_uso'::regclass)
     OR has_table_privilege('anon', 'public.optimizar_ruta_cupo_uso', 'SELECT')
     OR has_table_privilege('authenticated', 'public.optimizar_ruta_cupo_uso', 'SELECT')
     OR has_table_privilege('authenticated', 'public.optimizar_ruta_cupo_uso', 'INSERT')
     OR has_table_privilege('authenticated', 'public.optimizar_ruta_cupo_uso', 'UPDATE') THEN
    RAISE EXCEPTION 'mig NNN · optimizar_ruta_cupo_uso no quedó sólo de server';
  END IF;
  -- SEG-A no ve ninguna de las funciones de esta migración (lee sólo el catálogo).
  IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() x
              WHERE x.firma ~ '(cerrar_recorridos_vencidos|aplicar_cambio_de_parada|actualizar_recorrido_entrega|aplicar_orden_ruta|registrar_cambio_producto|crear_pedido_cambio_en_ruta|optimizar_ruta_consumir_cupo|recalcular_recorrido)\(') THEN
    RAISE EXCEPTION 'mig NNN · SEG-A ve una función de esta migración';
  END IF;
END
$post$;

COMMIT;

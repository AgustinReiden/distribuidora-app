-- =========================================================================
-- NNN · Ola 3, tarjeta T8: geolocalización y visitas (#1690, #1554, #1623)
--
-- 1 · Var-B1 (y Fr-B7 del lado del server): `registrar_visita_cliente` no era
--     idempotente: un reintento después de una respuesta perdida (o un doble
--     toque que llegaba dos veces) dejaba dos visitas. Ahora recibe `p_clave`
--     (uuid, DEFAULT NULL) con el mecanismo de las altas (`altas_por_clave`,
--     operación 'visita'): la misma clave, del mismo usuario y en la misma
--     sucursal, para el mismo cliente, devuelve la visita del primer intento
--     (`replay: true`) aunque el GPS del reintento sea otro (se volvió a
--     capturar: la visita es la misma). Otro cliente, otro usuario u otra
--     sucursal con esa clave se rechazan. Un intento rechazado (cliente que no
--     existe, ajeno, dado de baja…) no gasta la clave: se toma recién al
--     insertar la visita. Sin clave (un PWA de antes), como siempre: cada
--     llamada es una visita. La firma vieja (ocho parámetros) se DROPea: dos
--     sobrecargas con rangos superpuestos dan PGRST203. La llamada por nombre
--     del bundle viejo resuelve contra la nueva (p_clave tiene default).
--
-- 2 · `obtener_geolocalizacion_preventistas`:
--     · Var-B3 (decisión del dueño, 25/11): pedidos y visitas se agrupan por el
--       día argentino en que se cargaron y se tomó el GPS (`created_at`), no por
--       `pedidos.fecha`. Un pedido tomado en papel el lunes y cargado el martes
--       con fecha del lunes aparece el martes. El rango va como un intervalo
--       de timestamptz (`>=` medianoche argentina del desde, `<` la del día
--       siguiente al hasta), que es lo mismo que
--       `(created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
--       BETWEEN desde AND hasta` y usa los índices por `created_at`.
--     · Var-B2: un pedido cancelado no cuenta (ni en el total, ni como «sin
--       GPS», ni en el detalle).
--     · #1623 (VAR-02): el resumen sale de los preventistas con pedidos O con
--       visitas en el rango; uno con visitas y sin pedidos aparece con 0
--       pedidos, sus visitas y su última ubicación.
--     Las claves del JSON no cambian.
--
-- Lo que NO hace: permisos-B4 (el chofer lee las coordenadas del GPS del
-- pedido porque `authenticated` lee `pedidos` por tabla): ver el informe de la
-- tarjeta.
--
-- Premisas: los cuerpos vivos de la 548. Reaplicarla aborta (la firma vieja ya
-- no existe y el md5 del panel cambió).
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- La única DDL de tabla (el CHECK de altas_por_clave): su lock primero, sin
-- esperar. Si un alta la tiene tomada, falla al instante y se reintenta.
LOCK TABLE public.altas_por_clave IN ACCESS EXCLUSIVE MODE NOWAIT;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.registrar_visita_cliente(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb)', '12f29e709c505565bb86f589bf446dbd'),
    ('public.obtener_geolocalizacion_preventistas(date,date)', '5736d55dc4a2e8117d5613ec6e59a3f4')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = 'registrar_visita_cliente') <> 1 THEN
    RAISE EXCEPTION 'mig NNN · hay más de una firma de registrar_visita_cliente: rehacer sobre lo vigente';
  END IF;
  -- El CHECK de las operaciones de altas_por_clave, como lo dejó la 542.
  SELECT pg_get_constraintdef(oid) INTO v FROM pg_constraint
   WHERE conrelid = 'public.altas_por_clave'::regclass AND conname = 'altas_por_clave_operacion_check';
  IF v IS DISTINCT FROM $c$CHECK ((operacion = ANY (ARRAY['condicion_mayorista'::text, 'promocion'::text, 'cliente'::text, 'gasto'::text, 'empleado'::text])))$c$ THEN
    RAISE EXCEPTION 'mig NNN · el CHECK de altas_por_clave no es el de la 542 (%): rehacer sobre lo vigente', v;
  END IF;
END
$premisas$;

-- =========================================================================
-- 1 · Var-B1: la visita con clave
-- =========================================================================
ALTER TABLE public.altas_por_clave DROP CONSTRAINT altas_por_clave_operacion_check;
ALTER TABLE public.altas_por_clave ADD CONSTRAINT altas_por_clave_operacion_check
  CHECK (operacion = ANY (ARRAY['condicion_mayorista'::text, 'promocion'::text, 'cliente'::text,
                                'gasto'::text, 'empleado'::text, 'visita'::text]));

DROP FUNCTION public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamp with time zone, text, jsonb);

CREATE FUNCTION public.registrar_visita_cliente(
  p_cliente_id bigint,
  p_status text,
  p_lat numeric DEFAULT NULL::numeric,
  p_lng numeric DEFAULT NULL::numeric,
  p_accuracy numeric DEFAULT NULL::numeric,
  p_capturado_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_motivo_omision text DEFAULT NULL::text,
  p_diagnostico jsonb DEFAULT NULL::jsonb,
  p_clave uuid DEFAULT NULL::uuid
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_user_role text;
  v_sucursal bigint := current_sucursal_id();
  v_cliente RECORD;
  v_autorizado boolean;
  v_visita_id bigint;
  -- #1602: un extra; si no es un objeto chico, no se guarda (no se pierde la visita).
  v_diag jsonb := CASE WHEN jsonb_typeof(p_diagnostico) = 'object' AND octet_length(p_diagnostico::text) <= 300
                       THEN p_diagnostico END;
  -- Var-B1 (T8 de la ola 3): la visita es la del cliente; el GPS del reintento puede ser
  -- otro (se volvió a capturar) y sigue siendo la misma visita.
  v_contenido text := md5(jsonb_build_object('cliente', p_cliente_id)::text);
  v_previa public.altas_por_clave%ROWTYPE;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autenticado');
  END IF;
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay sucursal activa');
  END IF;

  IF p_status NOT IN ('ok','denied','unavailable','timeout','error') THEN
    RETURN jsonb_build_object('success', false, 'error', 'gps_status invalido');
  END IF;
  IF p_status = 'ok' AND (p_lat IS NULL OR p_lng IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'error', 'lat y lng requeridos cuando status=ok');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id AND COALESCE(activo, true);
  -- #1056: con `NOT IN` un rol NULL daba NULL y dejaba pasar.
  IF v_user_role IS NULL OR v_user_role NOT IN ('preventista', 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Rol no autorizado para marcar visitas');
  END IF;

  SELECT id, sucursal_id, reservado_admin, activo INTO v_cliente FROM clientes WHERE id = p_cliente_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cliente no existe');
  END IF;
  IF v_cliente.sucursal_id IS DISTINCT FROM v_sucursal THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cliente fuera de la sucursal activa');
  END IF;
  -- #1319: marcar una visita es operar, y con un cliente dado de baja no se opera.
  IF NOT v_cliente.activo THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cliente dado de baja: reactivalo desde Clientes para marcarle visitas');
  END IF;

  IF v_user_role IN ('preventista') THEN
    SELECT (
      NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = p_cliente_id)
      OR EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = p_cliente_id AND cp.preventista_id = v_user_id)
    ) INTO v_autorizado;
    IF NOT v_autorizado THEN
      RETURN jsonb_build_object('success', false, 'error', 'Cliente asignado a otro preventista');
    END IF;

    -- Reservado a administracion (mig 214). Sin excepcion de historial: marcar
    -- una visita es operar, no consultar el pasado.
    IF v_cliente.reservado_admin THEN
      RETURN jsonb_build_object('success', false, 'error', 'Cliente reservado a administración');
    END IF;
  END IF;

  -- Var-B1: la clave se toma recién acá, con todo validado (un rechazo de arriba no la gasta).
  -- Dos llamadas a la vez con la misma clave: la segunda espera el índice único de la primera
  -- y, si confirmó, devuelve su visita.
  IF p_clave IS NOT NULL THEN
    INSERT INTO altas_por_clave (clave, operacion, usuario_id, sucursal_id, contenido)
    VALUES (p_clave, 'visita', v_user_id, v_sucursal, v_contenido)
    ON CONFLICT (clave) DO NOTHING;
    IF NOT FOUND THEN
      SELECT * INTO v_previa FROM altas_por_clave WHERE clave = p_clave;
      IF v_previa.operacion <> 'visita' OR v_previa.usuario_id IS DISTINCT FROM v_user_id
         OR v_previa.sucursal_id <> v_sucursal THEN
        RETURN jsonb_build_object('success', false,
          'error', 'Esta clave ya se usó para otra operación: cerrá la ventana y marcá la visita de nuevo.');
      END IF;
      IF v_previa.contenido <> v_contenido THEN
        RETURN jsonb_build_object('success', false,
          'error', 'Esta clave ya se usó para la visita a otro cliente: cerrá la ventana y marcá la visita de nuevo.');
      END IF;
      IF v_previa.entidad_id IS NULL
         OR NOT EXISTS (SELECT 1 FROM visitas_cliente WHERE id = v_previa.entidad_id) THEN
        RETURN jsonb_build_object('success', false,
          'error', 'La visita del intento anterior ya no está: cerrá la ventana y marcala de nuevo.');
      END IF;
      RETURN jsonb_build_object('success', true, 'visita_id', v_previa.entidad_id, 'replay', true);
    END IF;
  END IF;

  INSERT INTO visitas_cliente (
    preventista_id, cliente_id, sucursal_id,
    gps_lat, gps_lng, gps_accuracy, gps_capturado_at, gps_status, gps_motivo_omision,
    gps_diagnostico
  ) VALUES (
    v_user_id, p_cliente_id, v_sucursal,
    CASE WHEN p_status = 'ok' THEN p_lat ELSE NULL END,
    CASE WHEN p_status = 'ok' THEN p_lng ELSE NULL END,
    CASE WHEN p_status = 'ok' THEN p_accuracy ELSE NULL END,
    public._gps_hora_de_captura(p_capturado_at),
    p_status,
    CASE WHEN p_status = 'ok' THEN NULL ELSE p_motivo_omision END,
    v_diag
  ) RETURNING id INTO v_visita_id;

  IF p_clave IS NOT NULL THEN
    UPDATE altas_por_clave SET entidad_id = v_visita_id WHERE clave = p_clave;
  END IF;

  RETURN jsonb_build_object('success', true, 'visita_id', v_visita_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamp with time zone, text, jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamp with time zone, text, jsonb, uuid) TO authenticated, service_role;

COMMENT ON FUNCTION public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamp with time zone, text, jsonb, uuid) IS
  'Registra una visita de cliente (ping del preventista). Acepta motivo de omision cuando gps_status no es ok. p_diagnostico (mig 507, #1602): el equipo al capturar; un bundle viejo no lo manda. p_clave (T8 de la ola 3, Var-B1): la clave del intento (altas_por_clave, operación visita); la misma clave para el mismo cliente devuelve la visita del primer intento (replay). Sin clave, cada llamada crea una visita nueva.';

-- =========================================================================
-- 2 · El panel: el día de la carga, sin cancelados, y los preventistas con visitas
-- =========================================================================
CREATE OR REPLACE FUNCTION public.obtener_geolocalizacion_preventistas(p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_user_role text;
  v_sucursal bigint := current_sucursal_id();
  v_fecha_desde date := COALESCE(p_fecha_desde, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
  v_fecha_hasta date := COALESCE(p_fecha_hasta, v_fecha_desde);
  -- Var-B3 (decisión del dueño, 25/11): el día argentino de la carga. De la medianoche
  -- argentina del desde a la del día siguiente al hasta, sobre `created_at` (sus índices).
  v_desde_ts timestamptz := v_fecha_desde::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires';
  v_hasta_ts timestamptz := (v_fecha_hasta + 1)::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires';
  v_result jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501';
  END IF;
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
  -- #1056: con `<>` un rol NULL daba NULL y dejaba pasar.
  IF v_user_role IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admins pueden ver geolocalizacion de preventistas' USING ERRCODE = '42501';
  END IF;
  WITH pedidos_rango AS (
    SELECT
      p.id              AS pedido_id,
      p.usuario_id      AS preventista_id,
      p.fecha,
      p.created_at      AS pedido_created_at,
      p.total,
      p.gps_lat,
      p.gps_lng,
      p.gps_accuracy,
      p.gps_capturado_at,
      p.gps_status,
      p.cliente_id,
      c.nombre_fantasia AS cliente_nombre,
      c.latitud         AS cliente_lat,
      c.longitud        AS cliente_lng,
      public.haversine_m(p.gps_lat, p.gps_lng, c.latitud, c.longitud) AS distancia_m
    FROM pedidos p
    LEFT JOIN clientes c ON c.id = p.cliente_id
    WHERE p.sucursal_id = v_sucursal
      AND p.created_at >= v_desde_ts
      AND p.created_at < v_hasta_ts
      AND p.usuario_id IS NOT NULL
      -- Var-B2: un pedido cancelado no es un pedido del día (ni «sin GPS»).
      AND p.estado <> 'cancelado'
  ),
  visitas_rango AS (
    SELECT
      v.id              AS visita_id,
      v.preventista_id,
      v.created_at      AS visita_created_at,
      v.gps_lat,
      v.gps_lng,
      v.gps_accuracy,
      v.gps_capturado_at,
      v.gps_status,
      v.cliente_id,
      c.nombre_fantasia AS cliente_nombre,
      c.latitud         AS cliente_lat,
      c.longitud        AS cliente_lng,
      public.haversine_m(v.gps_lat, v.gps_lng, c.latitud, c.longitud) AS distancia_m
    FROM visitas_cliente v
    LEFT JOIN clientes c ON c.id = v.cliente_id
    WHERE v.sucursal_id = v_sucursal
      AND v.created_at >= v_desde_ts
      AND v.created_at < v_hasta_ts
  ),
  -- #1623 (VAR-02): el preventista del día es el que cargó pedidos O marcó visitas.
  preventistas_rango AS (
    SELECT pr.preventista_id FROM pedidos_rango pr
    UNION
    SELECT v.preventista_id FROM visitas_rango v
  ),
  pedidos_por_preventista AS (
    SELECT
      pr.preventista_id,
      COUNT(*)::int AS total_pedidos,
      COUNT(*) FILTER (WHERE pr.gps_status = 'ok')::int AS pedidos_con_gps,
      COUNT(*) FILTER (WHERE pr.gps_status IS NULL OR pr.gps_status <> 'ok')::int AS pedidos_sin_gps,
      COUNT(*) FILTER (
        WHERE pr.gps_status = 'ok' AND pr.distancia_m IS NOT NULL AND pr.distancia_m >= 1000
      )::int AS pedidos_lejos
    FROM pedidos_rango pr
    GROUP BY pr.preventista_id
  ),
  preventistas_resumen AS (
    SELECT
      pv.preventista_id,
      per.nombre AS preventista_nombre,
      COALESCE(pp.total_pedidos, 0) AS total_pedidos,
      COALESCE(pp.pedidos_con_gps, 0) AS pedidos_con_gps,
      COALESCE(pp.pedidos_sin_gps, 0) AS pedidos_sin_gps,
      COALESCE(pp.pedidos_lejos, 0) AS pedidos_lejos,
      (SELECT COUNT(*) FROM visitas_rango v WHERE v.preventista_id = pv.preventista_id)::int AS total_visitas,
      (
        SELECT jsonb_build_object(
          'lat', e.lat,
          'lng', e.lng,
          'capturado_at', e.capturado_at,
          'tipo', e.tipo,
          'id', e.id
        )
        FROM (
          SELECT pr2.gps_lat AS lat, pr2.gps_lng AS lng, pr2.gps_capturado_at AS capturado_at,
                 'pedido'::text AS tipo, pr2.pedido_id AS id
          FROM pedidos_rango pr2
          WHERE pr2.preventista_id = pv.preventista_id AND pr2.gps_status = 'ok'
          UNION ALL
          SELECT v.gps_lat AS lat, v.gps_lng AS lng, v.gps_capturado_at AS capturado_at,
                 'visita'::text AS tipo, v.visita_id AS id
          FROM visitas_rango v
          WHERE v.preventista_id = pv.preventista_id AND v.gps_status = 'ok'
        ) e
        ORDER BY e.capturado_at DESC NULLS LAST
        LIMIT 1
      ) AS ultima_ubicacion
    FROM preventistas_rango pv
    JOIN perfiles per ON per.id = pv.preventista_id AND per.rol IN ('preventista')
    LEFT JOIN pedidos_por_preventista pp ON pp.preventista_id = pv.preventista_id
  )
  SELECT jsonb_build_object(
    'fecha_desde', v_fecha_desde,
    'fecha_hasta', v_fecha_hasta,
    'preventistas', COALESCE(
      (SELECT jsonb_agg(to_jsonb(preventistas_resumen.*) ORDER BY preventista_nombre)
       FROM preventistas_resumen),
      '[]'::jsonb
    ),
    'pedidos', COALESCE(
      (SELECT jsonb_agg(to_jsonb(pr.*) ORDER BY pr.pedido_created_at NULLS LAST)
       FROM pedidos_rango pr
       JOIN perfiles per ON per.id = pr.preventista_id AND per.rol IN ('preventista')),
      '[]'::jsonb
    ),
    'visitas', COALESCE(
      (SELECT jsonb_agg(to_jsonb(v.*) ORDER BY v.visita_created_at NULLS LAST)
       FROM visitas_rango v
       JOIN perfiles per ON per.id = v.preventista_id AND per.rol IN ('preventista')),
      '[]'::jsonb
    )
  ) INTO v_result;
  RETURN v_result;
END;
$function$;

COMMENT ON FUNCTION public.obtener_geolocalizacion_preventistas(date, date) IS
  'Panel admin de geolocalizacion: resumen por preventista + detalle de pedidos y visitas. Umbral pedidos_lejos = 1 km (espejo de ANOMALIA_DISTANCIA_METROS en frontend). Desde T8 de la ola 3: agrupa pedidos y visitas por el día argentino de la carga (created_at, Var-B3), sin pedidos cancelados (Var-B2), y el resumen incluye a los preventistas con visitas y sin pedidos (#1623).';

-- ---------------------------------------------------------------------------
-- Poscondiciones
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  F_VIS CONSTANT text := 'public.registrar_visita_cliente(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb,uuid)';
  F_GEO CONSTANT text := 'public.obtener_geolocalizacion_preventistas(date,date)';
  r record;
BEGIN
  IF to_regprocedure(F_VIS) IS NULL
     OR (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'public' AND p.proname = 'registrar_visita_cliente') <> 1 THEN
    RAISE EXCEPTION 'mig NNN · registrar_visita_cliente no quedó con una sola firma, la de p_clave';
  END IF;
  FOR r IN SELECT unnest(ARRAY[F_VIS, F_GEO]) AS f LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = r.f::regprocedure AND prosecdef
                    AND proconfig @> ARRAY['search_path=public, pg_temp']) THEN
      RAISE EXCEPTION 'mig NNN · % quedó sin DEFINER o sin pg_temp en su search_path', r.f;
    END IF;
    IF has_function_privilege('anon', r.f, 'EXECUTE')
       OR NOT has_function_privilege('authenticated', r.f, 'EXECUTE')
       OR NOT has_function_privilege('service_role', r.f, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig NNN · los permisos de % no son los esperados', r.f;
    END IF;
  END LOOP;
  IF (SELECT position('altas_por_clave' IN prosrc) FROM pg_proc WHERE oid = F_VIS::regprocedure) = 0 THEN
    RAISE EXCEPTION 'mig NNN · registrar_visita_cliente no mira la clave';
  END IF;
  IF (SELECT prosrc !~ 'p\.created_at >= v_desde_ts' OR prosrc !~ 'v\.created_at >= v_desde_ts'
             OR prosrc !~ 'p\.estado <> ''cancelado''' OR prosrc !~ 'FROM preventistas_rango pv'
             OR prosrc ~ 'p\.fecha BETWEEN'
        FROM pg_proc WHERE oid = F_GEO::regprocedure) THEN
    RAISE EXCEPTION 'mig NNN · el panel de geolocalización no quedó como se esperaba';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.altas_por_clave'::regclass AND conname = 'altas_por_clave_operacion_check'
                    AND pg_get_constraintdef(oid) LIKE '%''empleado''::text, ''visita''::text%') THEN
    RAISE EXCEPTION 'mig NNN · el CHECK de altas_por_clave no quedó con visita';
  END IF;
END
$post$;

COMMIT;

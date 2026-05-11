-- =========================================================================
-- 040_pedidos_geolocalizacion.sql
--
-- Geolocalizacion de preventistas via check-in al confirmar un pedido.
--
--   1. Columnas gps_* en public.pedidos (todas nullable, retro-compatibles).
--
--   2. Helper public.haversine_m(lat1, lng1, lat2, lng2) -> numeric (metros).
--
--   3. RPC public.registrar_geolocalizacion_pedido(p_pedido_id, p_lat, p_lng,
--      p_accuracy, p_status). Permite al preventista que creo el pedido (o un
--      admin) setear el GPS una sola vez. Idempotente: si gps_status ya esta
--      seteado, no se sobrescribe.
--
--   4. RPC public.obtener_geolocalizacion_preventistas(p_fecha_desde,
--      p_fecha_hasta) -> jsonb. Solo admin. Devuelve el resumen por
--      preventista + detalle por pedido para el panel de control admin.
--      Scope a current_sucursal_id().
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. Columnas GPS en pedidos
-- -------------------------------------------------------------------------

ALTER TABLE public.pedidos
  ADD COLUMN IF NOT EXISTS gps_lat numeric(10,7),
  ADD COLUMN IF NOT EXISTS gps_lng numeric(10,7),
  ADD COLUMN IF NOT EXISTS gps_accuracy numeric(8,2),
  ADD COLUMN IF NOT EXISTS gps_capturado_at timestamptz,
  ADD COLUMN IF NOT EXISTS gps_status text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'pedidos_gps_status_check'
      AND conrelid = 'public.pedidos'::regclass
  ) THEN
    ALTER TABLE public.pedidos
      ADD CONSTRAINT pedidos_gps_status_check
      CHECK (gps_status IS NULL OR gps_status IN ('ok','denied','unavailable','timeout','error'));
  END IF;
END $$;

COMMENT ON COLUMN public.pedidos.gps_lat IS 'Latitud del preventista al confirmar el pedido (check-in). Null si no se capturo.';
COMMENT ON COLUMN public.pedidos.gps_lng IS 'Longitud del preventista al confirmar el pedido.';
COMMENT ON COLUMN public.pedidos.gps_accuracy IS 'Precision del GPS en metros (acc del navegador).';
COMMENT ON COLUMN public.pedidos.gps_capturado_at IS 'Timestamp del check-in (lado cliente).';
COMMENT ON COLUMN public.pedidos.gps_status IS 'Estado del check-in: ok | denied | unavailable | timeout | error. Null para pedidos previos a la migracion.';

-- Indice para queries del panel admin (pedidos del dia con GPS por preventista)
CREATE INDEX IF NOT EXISTS idx_pedidos_gps_capturado_at
  ON public.pedidos (gps_capturado_at DESC)
  WHERE gps_status = 'ok';

-- -------------------------------------------------------------------------
-- 2. Helper haversine_m
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.haversine_m(
  lat1 numeric, lng1 numeric, lat2 numeric, lng2 numeric
) RETURNS numeric
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
  SELECT CASE
    WHEN lat1 IS NULL OR lng1 IS NULL OR lat2 IS NULL OR lng2 IS NULL THEN NULL
    ELSE (
      6371000 * 2 * asin(
        sqrt(
          power(sin(radians((lat2 - lat1) / 2)), 2) +
          cos(radians(lat1)) * cos(radians(lat2)) *
          power(sin(radians((lng2 - lng1) / 2)), 2)
        )
      )
    )::numeric
  END;
$$;

COMMENT ON FUNCTION public.haversine_m(numeric, numeric, numeric, numeric) IS
  'Distancia en metros entre dos coordenadas (lat,lng) usando formula haversine. Devuelve NULL si algun argumento es NULL.';

GRANT EXECUTE ON FUNCTION public.haversine_m(numeric, numeric, numeric, numeric) TO anon, authenticated, service_role;

-- -------------------------------------------------------------------------
-- 3. RPC registrar_geolocalizacion_pedido
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.registrar_geolocalizacion_pedido(
  p_pedido_id bigint,
  p_status text,
  p_lat numeric DEFAULT NULL,
  p_lng numeric DEFAULT NULL,
  p_accuracy numeric DEFAULT NULL,
  p_capturado_at timestamptz DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_user_role text;
  v_pedido RECORD;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autenticado');
  END IF;

  IF p_status NOT IN ('ok','denied','unavailable','timeout','error') THEN
    RETURN jsonb_build_object('success', false, 'error', 'gps_status invalido');
  END IF;

  -- Si status='ok', lat y lng son obligatorios.
  IF p_status = 'ok' AND (p_lat IS NULL OR p_lng IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'error', 'lat y lng requeridos cuando status=ok');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;

  SELECT id, usuario_id, sucursal_id, gps_status INTO v_pedido
  FROM pedidos
  WHERE id = p_pedido_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no existe');
  END IF;

  -- Sucursal: el RPC ya corre con SECURITY DEFINER asi que no depende de
  -- current_sucursal_id(); igual validamos que el pedido pertenezca a la
  -- sucursal activa para evitar cross-sucursal en multi-tenant.
  IF v_pedido.sucursal_id IS DISTINCT FROM current_sucursal_id() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido fuera de la sucursal activa');
  END IF;

  -- Autorizacion: dueño del pedido (preventista que lo creo) o admin.
  IF v_pedido.usuario_id IS DISTINCT FROM v_user_id AND v_user_role <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  -- Idempotente: no sobrescribir un check-in ya registrado.
  IF v_pedido.gps_status IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'ya_registrado', true);
  END IF;

  UPDATE pedidos SET
    gps_status = p_status,
    gps_lat = CASE WHEN p_status = 'ok' THEN p_lat ELSE NULL END,
    gps_lng = CASE WHEN p_status = 'ok' THEN p_lng ELSE NULL END,
    gps_accuracy = CASE WHEN p_status = 'ok' THEN p_accuracy ELSE NULL END,
    gps_capturado_at = COALESCE(p_capturado_at, now())
  WHERE id = p_pedido_id;

  RETURN jsonb_build_object('success', true);
END;
$$;

ALTER FUNCTION public.registrar_geolocalizacion_pedido(bigint, text, numeric, numeric, numeric, timestamptz) OWNER TO postgres;

COMMENT ON FUNCTION public.registrar_geolocalizacion_pedido(bigint, text, numeric, numeric, numeric, timestamptz) IS
  'Registra el check-in GPS de un pedido. Solo el preventista dueño o un admin. Idempotente: no sobrescribe un check-in existente.';

GRANT EXECUTE ON FUNCTION public.registrar_geolocalizacion_pedido(bigint, text, numeric, numeric, numeric, timestamptz)
  TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 4. RPC obtener_geolocalizacion_preventistas
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_geolocalizacion_preventistas(
  p_fecha_desde date DEFAULT NULL,
  p_fecha_hasta date DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_user_role text;
  v_sucursal bigint := current_sucursal_id();
  v_fecha_desde date := COALESCE(p_fecha_desde, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
  v_fecha_hasta date := COALESCE(p_fecha_hasta, v_fecha_desde);
  v_result jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501';
  END IF;
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
  IF v_user_role <> 'admin' THEN
    RAISE EXCEPTION 'Solo admins pueden ver geolocalizacion de preventistas' USING ERRCODE = '42501';
  END IF;

  WITH pedidos_rango AS (
    SELECT
      p.id              AS pedido_id,
      p.usuario_id      AS preventista_id,
      p.fecha,
      p.total,
      p.gps_lat,
      p.gps_lng,
      p.gps_accuracy,
      p.gps_capturado_at,
      p.gps_status,
      p.cliente_id,
      c.nombre          AS cliente_nombre,
      c.latitud         AS cliente_lat,
      c.longitud        AS cliente_lng,
      public.haversine_m(p.gps_lat, p.gps_lng, c.latitud, c.longitud) AS distancia_m
    FROM pedidos p
    LEFT JOIN clientes c ON c.id = p.cliente_id
    WHERE p.sucursal_id = v_sucursal
      AND p.fecha BETWEEN v_fecha_desde AND v_fecha_hasta
      AND p.usuario_id IS NOT NULL
  ),
  preventistas_resumen AS (
    SELECT
      pr.preventista_id,
      per.nombre AS preventista_nombre,
      COUNT(*)::int AS total_pedidos,
      COUNT(*) FILTER (WHERE pr.gps_status = 'ok')::int AS pedidos_con_gps,
      COUNT(*) FILTER (WHERE pr.gps_status IS NULL OR pr.gps_status <> 'ok')::int AS pedidos_sin_gps,
      COUNT(*) FILTER (
        WHERE pr.gps_status = 'ok' AND pr.distancia_m IS NOT NULL AND pr.distancia_m >= 2000
      )::int AS pedidos_lejos,
      (
        SELECT jsonb_build_object(
          'lat', pr2.gps_lat,
          'lng', pr2.gps_lng,
          'capturado_at', pr2.gps_capturado_at,
          'pedido_id', pr2.pedido_id
        )
        FROM pedidos_rango pr2
        WHERE pr2.preventista_id = pr.preventista_id
          AND pr2.gps_status = 'ok'
        ORDER BY pr2.gps_capturado_at DESC NULLS LAST
        LIMIT 1
      ) AS ultima_ubicacion
    FROM pedidos_rango pr
    LEFT JOIN perfiles per ON per.id = pr.preventista_id
    WHERE per.rol = 'preventista'
    GROUP BY pr.preventista_id, per.nombre
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
      (SELECT jsonb_agg(to_jsonb(pr.*) ORDER BY pr.gps_capturado_at NULLS LAST)
       FROM pedidos_rango pr
       JOIN perfiles per ON per.id = pr.preventista_id AND per.rol = 'preventista'),
      '[]'::jsonb
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

ALTER FUNCTION public.obtener_geolocalizacion_preventistas(date, date) OWNER TO postgres;

COMMENT ON FUNCTION public.obtener_geolocalizacion_preventistas(date, date) IS
  'Panel admin de geolocalizacion: resumen por preventista + detalle de pedidos con GPS y distancia al cliente. Scope a current_sucursal_id().';

GRANT EXECUTE ON FUNCTION public.obtener_geolocalizacion_preventistas(date, date) TO authenticated, service_role;

COMMIT;

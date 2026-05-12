-- =========================================================================
-- 043_geolocalizacion_umbral_1km.sql
--
-- Baja el umbral "pedido lejos del cliente" de 2 km a 1 km en el campo
-- agregado `pedidos_lejos` del RPC `obtener_geolocalizacion_preventistas`.
-- El semaforo del frontend ya usa la constante ANOMALIA_DISTANCIA_METROS
-- (= 1000); este RPC tenia el valor literal espejo y queda en sync.
--
-- CREATE OR REPLACE sobre la version de 042 cambiando un solo numero.
-- =========================================================================

BEGIN;

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
      AND p.fecha BETWEEN v_fecha_desde AND v_fecha_hasta
      AND p.usuario_id IS NOT NULL
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
      AND (v.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN v_fecha_desde AND v_fecha_hasta
  ),
  preventistas_resumen AS (
    SELECT
      pr.preventista_id,
      per.nombre AS preventista_nombre,
      COUNT(*)::int AS total_pedidos,
      COUNT(*) FILTER (WHERE pr.gps_status = 'ok')::int AS pedidos_con_gps,
      COUNT(*) FILTER (WHERE pr.gps_status IS NULL OR pr.gps_status <> 'ok')::int AS pedidos_sin_gps,
      COUNT(*) FILTER (
        WHERE pr.gps_status = 'ok' AND pr.distancia_m IS NOT NULL AND pr.distancia_m >= 1000
      )::int AS pedidos_lejos,
      (SELECT COUNT(*) FROM visitas_rango v WHERE v.preventista_id = pr.preventista_id)::int AS total_visitas,
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
          WHERE pr2.preventista_id = pr.preventista_id AND pr2.gps_status = 'ok'
          UNION ALL
          SELECT v.gps_lat AS lat, v.gps_lng AS lng, v.gps_capturado_at AS capturado_at,
                 'visita'::text AS tipo, v.visita_id AS id
          FROM visitas_rango v
          WHERE v.preventista_id = pr.preventista_id AND v.gps_status = 'ok'
        ) e
        ORDER BY e.capturado_at DESC NULLS LAST
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
      (SELECT jsonb_agg(to_jsonb(pr.*) ORDER BY pr.pedido_created_at NULLS LAST)
       FROM pedidos_rango pr
       JOIN perfiles per ON per.id = pr.preventista_id AND per.rol = 'preventista'),
      '[]'::jsonb
    ),
    'visitas', COALESCE(
      (SELECT jsonb_agg(to_jsonb(v.*) ORDER BY v.visita_created_at NULLS LAST)
       FROM visitas_rango v
       JOIN perfiles per ON per.id = v.preventista_id AND per.rol = 'preventista'),
      '[]'::jsonb
    )
  ) INTO v_result;
  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.obtener_geolocalizacion_preventistas(date, date) IS
  'Panel admin de geolocalizacion: resumen por preventista + detalle de pedidos y visitas. Umbral pedidos_lejos = 1 km (espejo de ANOMALIA_DISTANCIA_METROS en frontend).';

COMMIT;

-- =========================================================================
-- 041_geolocalizacion_pedido_created_at.sql
--
-- Agrega el campo `created_at` del pedido al output de la RPC
-- `obtener_geolocalizacion_preventistas`. El panel admin lo usa para
-- mostrar la hora exacta en que se creo cada pedido (no depende de
-- gps_capturado_at, que puede ser null si el preventista no autorizo GPS).
--
-- CREATE OR REPLACE sobre la definicion de la migracion 040, agregando
-- `p.created_at AS pedido_created_at` al SELECT del CTE pedidos_rango.
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
      (SELECT jsonb_agg(to_jsonb(pr.*) ORDER BY pr.pedido_created_at NULLS LAST)
       FROM pedidos_rango pr
       JOIN perfiles per ON per.id = pr.preventista_id AND per.rol = 'preventista'),
      '[]'::jsonb
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.obtener_geolocalizacion_preventistas(date, date) IS
  'Panel admin de geolocalizacion: resumen por preventista + detalle de pedidos con GPS, distancia al cliente y created_at del pedido. Scope a current_sucursal_id().';

COMMIT;

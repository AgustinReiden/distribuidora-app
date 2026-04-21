-- ============================================================================
-- RPC: obtener_estadisticas_pedidos
--
-- Calcula estadísticas de pedidos directamente en la base de datos,
-- evitando descargar todos los pedidos al cliente para calcularlas en JS.
--
-- EJECUTAR MANUALMENTE: Este script no puede ejecutarse via MCP por
-- limitaciones de permisos. Ejecutar desde el SQL Editor de Supabase Dashboard.
-- ============================================================================

CREATE OR REPLACE FUNCTION obtener_estadisticas_pedidos(
  p_fecha_desde TIMESTAMPTZ DEFAULT NULL,
  p_fecha_hasta TIMESTAMPTZ DEFAULT NULL,
  p_usuario_id  UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'total', COUNT(*)::int,
    'pendientes', COUNT(*) FILTER (WHERE estado = 'pendiente')::int,
    'en_preparacion', COUNT(*) FILTER (WHERE estado = 'en_preparacion')::int,
    'en_reparto', COUNT(*) FILTER (WHERE estado IN ('en_reparto', 'asignado'))::int,
    'entregados', COUNT(*) FILTER (WHERE estado = 'entregado')::int,
    'cancelados', COUNT(*) FILTER (WHERE estado = 'cancelado')::int,
    'total_ventas', COALESCE(SUM(total) FILTER (WHERE estado = 'entregado'), 0)::numeric(12,2),
    'promedio_ticket', COALESCE(
      AVG(total) FILTER (WHERE estado = 'entregado'), 0
    )::numeric(12,2),
    'por_estado', jsonb_object_agg_strict(
      estado, cnt
    )
  ) INTO v_result
  FROM (
    SELECT
      p.estado,
      p.total,
      COUNT(*) OVER (PARTITION BY p.estado) AS cnt
    FROM pedidos p
    WHERE
      (p_fecha_desde IS NULL OR p.created_at >= p_fecha_desde)
      AND (p_fecha_hasta IS NULL OR p.created_at <= p_fecha_hasta)
      AND (p_usuario_id IS NULL OR p.usuario_id = p_usuario_id)
  ) sub;

  -- Si no hay pedidos, retornar objeto vacío con defaults
  IF v_result IS NULL THEN
    v_result := jsonb_build_object(
      'total', 0,
      'pendientes', 0,
      'en_preparacion', 0,
      'en_reparto', 0,
      'entregados', 0,
      'cancelados', 0,
      'total_ventas', 0,
      'promedio_ticket', 0,
      'por_estado', '{}'::jsonb
    );
  END IF;

  RETURN v_result;
END;
$$;

-- Alternativa simplificada si jsonb_object_agg_strict no está disponible
-- (disponible desde PostgreSQL 16+). Si falla, usar esta versión:
--
-- CREATE OR REPLACE FUNCTION obtener_estadisticas_pedidos(
--   p_fecha_desde TIMESTAMPTZ DEFAULT NULL,
--   p_fecha_hasta TIMESTAMPTZ DEFAULT NULL,
--   p_usuario_id  UUID DEFAULT NULL
-- )
-- RETURNS JSONB
-- LANGUAGE sql
-- SECURITY DEFINER
-- AS $$
--   SELECT jsonb_build_object(
--     'total', COUNT(*)::int,
--     'pendientes', COUNT(*) FILTER (WHERE estado = 'pendiente')::int,
--     'en_preparacion', COUNT(*) FILTER (WHERE estado = 'en_preparacion')::int,
--     'en_reparto', COUNT(*) FILTER (WHERE estado IN ('en_reparto', 'asignado'))::int,
--     'entregados', COUNT(*) FILTER (WHERE estado = 'entregado')::int,
--     'cancelados', COUNT(*) FILTER (WHERE estado = 'cancelado')::int,
--     'total_ventas', COALESCE(SUM(total) FILTER (WHERE estado = 'entregado'), 0)::numeric(12,2),
--     'promedio_ticket', COALESCE(AVG(total) FILTER (WHERE estado = 'entregado'), 0)::numeric(12,2),
--     'por_estado', COALESCE(
--       (SELECT jsonb_object_agg(estado, cnt)
--        FROM (
--          SELECT estado, COUNT(*)::int AS cnt
--          FROM pedidos
--          WHERE (p_fecha_desde IS NULL OR created_at >= p_fecha_desde)
--            AND (p_fecha_hasta IS NULL OR created_at <= p_fecha_hasta)
--            AND (p_usuario_id IS NULL OR usuario_id = p_usuario_id)
--          GROUP BY estado
--        ) s),
--       '{}'::jsonb
--     )
--   )
--   FROM pedidos
--   WHERE (p_fecha_desde IS NULL OR created_at >= p_fecha_desde)
--     AND (p_fecha_hasta IS NULL OR created_at <= p_fecha_hasta)
--     AND (p_usuario_id IS NULL OR usuario_id = p_usuario_id);
-- $$;

COMMENT ON FUNCTION obtener_estadisticas_pedidos IS
  'Calcula estadísticas agregadas de pedidos sin descargar datos al cliente. '
  'Soporta filtros opcionales por rango de fechas y usuario.';

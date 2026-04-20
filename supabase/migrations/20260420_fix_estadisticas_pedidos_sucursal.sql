-- ============================================================================
-- Fix: obtener_estadisticas_pedidos ahora filtra por sucursal activa
--
-- Antes: SECURITY DEFINER sin filtro multi-tenant. Cualquier usuario
-- autenticado podia leer totales de ventas globales cross-sucursal.
--
-- Ahora: filtra por current_sucursal_id(). Si no hay sucursal activa,
-- lanza excepcion 42501 (insufficient_privilege).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_estadisticas_pedidos(
  p_fecha_desde TIMESTAMPTZ DEFAULT NULL,
  p_fecha_hasta TIMESTAMPTZ DEFAULT NULL,
  p_usuario_id  UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal_id BIGINT;
  v_result JSONB;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'total', COUNT(*)::int,
    'pendientes', COUNT(*) FILTER (WHERE estado = 'pendiente')::int,
    'en_preparacion', COUNT(*) FILTER (WHERE estado = 'en_preparacion')::int,
    'en_reparto', COUNT(*) FILTER (WHERE estado IN ('en_reparto', 'asignado'))::int,
    'entregados', COUNT(*) FILTER (WHERE estado = 'entregado')::int,
    'cancelados', COUNT(*) FILTER (WHERE estado = 'cancelado')::int,
    'total_ventas', COALESCE(SUM(total) FILTER (WHERE estado = 'entregado'), 0)::numeric(12,2),
    'promedio_ticket', COALESCE(AVG(total) FILTER (WHERE estado = 'entregado'), 0)::numeric(12,2),
    'por_estado', COALESCE(
      (SELECT jsonb_object_agg(estado, cnt)
       FROM (
         SELECT p.estado, COUNT(*)::int AS cnt
         FROM pedidos p
         WHERE p.sucursal_id = v_sucursal_id
           AND (p_fecha_desde IS NULL OR p.created_at >= p_fecha_desde)
           AND (p_fecha_hasta IS NULL OR p.created_at <= p_fecha_hasta)
           AND (p_usuario_id IS NULL OR p.usuario_id = p_usuario_id)
         GROUP BY p.estado
       ) s),
      '{}'::jsonb
    )
  ) INTO v_result
  FROM pedidos p
  WHERE p.sucursal_id = v_sucursal_id
    AND (p_fecha_desde IS NULL OR p.created_at >= p_fecha_desde)
    AND (p_fecha_hasta IS NULL OR p.created_at <= p_fecha_hasta)
    AND (p_usuario_id IS NULL OR p.usuario_id = p_usuario_id);

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

COMMENT ON FUNCTION public.obtener_estadisticas_pedidos IS
  'Estadisticas agregadas de pedidos para la sucursal activa. '
  'Requiere current_sucursal_id() no nulo. Filtra por rango opcional de fechas y usuario.';

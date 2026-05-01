-- Migración 029 — Fix: RPCs de reportes filtran por pedidos.fecha (no created_at)
--
-- Bug detectado: bot reportaba $16.518.510 para abril 2026 mientras la app
-- dashboard reportaba $16.212.810. Diferencia = 8 pedidos con fecha=30/03
-- pero created_at=01/04 (cargados al día siguiente). El RPC los contaba como
-- abril, el dashboard como marzo.
--
-- Fix: pedidos.fecha es la fecha de venta canónica (la que la app usa).
-- pedidos.created_at es solo de auditoría. Reescribir las RPCs para filtrar
-- por fecha (DATE) directamente — más simple y consistente con la app.
--
-- RPCs afectadas (firma sin cambios — el bot edge function no necesita redeploy):
--   * bot_ventas_periodo (mig 022)
--   * bot_ventas_por_preventista (mig 025)
--   * bot_mis_ventas (mig 025)
--   * bot_ranking_preventistas_por_producto (mig 027)
--
-- Otras RPCs NO se tocan acá (alcance acotado):
--   * bot_pendientes_pago — usa created_at para "días desde el pedido más viejo",
--     que es semánticamente correcto (cuánto hace que se grabó la deuda).
--   * bot_historico_pedidos_cliente, bot_productos_recurrentes_cliente — usan
--     `created_at > now() - interval` (lookback relativo). Cambio menor que no
--     afecta totales agregados; se evalúa en otra iter si los preventistas
--     reportan inconsistencia.
--   * bot_compras_periodo — usa compras.fecha_compra, OK.

-- ============================================================================
-- 1. bot_ventas_periodo
-- ============================================================================
CREATE OR REPLACE FUNCTION public.bot_ventas_periodo(
  p_desde DATE,
  p_hasta DATE,
  p_sucursal_id BIGINT,
  p_limit INT DEFAULT 10
)
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE resultado JSON;
BEGIN
  WITH ventas_filtradas AS (
    SELECT id, cliente_id, total, fecha
    FROM pedidos
    WHERE sucursal_id = p_sucursal_id
      AND fecha BETWEEN p_desde AND p_hasta
      AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
  ),
  top_clientes AS (
    SELECT c.id, c.codigo, c.nombre_fantasia, c.razon_social,
      SUM(v.total) AS total_comprado, COUNT(*) AS pedidos
    FROM ventas_filtradas v JOIN clientes c ON c.id = v.cliente_id
    GROUP BY c.id, c.codigo, c.nombre_fantasia, c.razon_social
    ORDER BY SUM(v.total) DESC LIMIT p_limit
  ),
  top_productos AS (
    SELECT p.id, p.codigo, p.nombre, SUM(pi.cantidad) AS unidades, SUM(pi.subtotal) AS facturado
    FROM ventas_filtradas v
    JOIN pedido_items pi ON pi.pedido_id = v.id
    JOIN productos p ON p.id = pi.producto_id
    GROUP BY p.id, p.codigo, p.nombre
    ORDER BY SUM(pi.subtotal) DESC LIMIT p_limit
  )
  SELECT json_build_object(
    'desde', p_desde, 'hasta', p_hasta,
    'total_ventas', (SELECT COALESCE(SUM(total), 0) FROM ventas_filtradas),
    'pedidos_count', (SELECT COUNT(*) FROM ventas_filtradas),
    'ticket_promedio', (SELECT CASE WHEN COUNT(*)>0 THEN ROUND(AVG(total),2) ELSE 0 END FROM ventas_filtradas),
    'top_clientes', COALESCE((SELECT json_agg(row_to_json(tc.*)) FROM top_clientes tc), '[]'::JSON),
    'top_productos', COALESCE((SELECT json_agg(row_to_json(tp.*)) FROM top_productos tp), '[]'::JSON)
  ) INTO resultado;
  RETURN resultado;
END;
$$;

ALTER FUNCTION public.bot_ventas_periodo(DATE, DATE, BIGINT, INT) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.bot_ventas_periodo(DATE, DATE, BIGINT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_ventas_periodo(DATE, DATE, BIGINT, INT) TO service_role;

-- ============================================================================
-- 2. bot_ventas_por_preventista
-- ============================================================================
CREATE OR REPLACE FUNCTION public.bot_ventas_por_preventista(
  p_desde DATE,
  p_hasta DATE,
  p_sucursal_id BIGINT,
  p_solo_preventistas BOOLEAN DEFAULT TRUE,
  p_limit INT DEFAULT 25
)
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE resultado JSON;
BEGIN
  WITH ventas_filtradas AS (
    SELECT p.id, p.usuario_id, p.total
    FROM pedidos p
    LEFT JOIN perfiles pf ON pf.id = p.usuario_id
    WHERE p.sucursal_id = p_sucursal_id
      AND p.fecha BETWEEN p_desde AND p_hasta
      AND COALESCE(p.estado, '') NOT IN ('cancelado', 'anulado')
      AND (NOT p_solo_preventistas OR pf.rol = 'preventista')
  ),
  por_usuario AS (
    SELECT
      v.usuario_id,
      pf.nombre,
      pf.rol,
      COUNT(*)         AS pedidos,
      SUM(v.total)     AS total_vendido,
      ROUND(AVG(v.total), 2) AS ticket_promedio
    FROM ventas_filtradas v
    LEFT JOIN perfiles pf ON pf.id = v.usuario_id
    GROUP BY v.usuario_id, pf.nombre, pf.rol
    ORDER BY SUM(v.total) DESC
    LIMIT p_limit
  )
  SELECT json_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'solo_preventistas', p_solo_preventistas,
    'total_ventas', (SELECT COALESCE(SUM(total), 0) FROM ventas_filtradas),
    'pedidos_count', (SELECT COUNT(*) FROM ventas_filtradas),
    'preventistas_count', (SELECT COUNT(*) FROM por_usuario),
    'preventistas', COALESCE(
      (SELECT json_agg(row_to_json(pu.*)) FROM por_usuario pu),
      '[]'::JSON
    )
  ) INTO resultado;
  RETURN resultado;
END;
$$;

ALTER FUNCTION public.bot_ventas_por_preventista(DATE, DATE, BIGINT, BOOLEAN, INT) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.bot_ventas_por_preventista(DATE, DATE, BIGINT, BOOLEAN, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_ventas_por_preventista(DATE, DATE, BIGINT, BOOLEAN, INT) TO service_role;

-- ============================================================================
-- 3. bot_mis_ventas
-- ============================================================================
CREATE OR REPLACE FUNCTION public.bot_mis_ventas(
  p_preventista_id UUID,
  p_desde DATE,
  p_hasta DATE,
  p_sucursal_id BIGINT,
  p_limit INT DEFAULT 10
)
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE resultado JSON;
BEGIN
  WITH ventas_filtradas AS (
    SELECT p.id, p.cliente_id, p.total
    FROM pedidos p
    WHERE p.sucursal_id = p_sucursal_id
      AND p.usuario_id  = p_preventista_id
      AND p.fecha BETWEEN p_desde AND p_hasta
      AND COALESCE(p.estado, '') NOT IN ('cancelado', 'anulado')
  ),
  top_clientes AS (
    SELECT
      c.id          AS cliente_id,
      c.codigo      AS cliente_codigo,
      c.nombre_fantasia,
      c.razon_social,
      SUM(v.total)  AS total_comprado,
      COUNT(*)      AS pedidos
    FROM ventas_filtradas v
    JOIN clientes c ON c.id = v.cliente_id
    GROUP BY c.id, c.codigo, c.nombre_fantasia, c.razon_social
    ORDER BY SUM(v.total) DESC
    LIMIT p_limit
  )
  SELECT json_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'preventista_id', p_preventista_id,
    'total_ventas', (SELECT COALESCE(SUM(total), 0) FROM ventas_filtradas),
    'pedidos_count', (SELECT COUNT(*) FROM ventas_filtradas),
    'ticket_promedio', (
      SELECT CASE WHEN COUNT(*) > 0 THEN ROUND(AVG(total), 2) ELSE 0 END
      FROM ventas_filtradas
    ),
    'clientes_distintos', (SELECT COUNT(DISTINCT cliente_id) FROM ventas_filtradas),
    'top_clientes', COALESCE(
      (SELECT json_agg(row_to_json(tc.*)) FROM top_clientes tc),
      '[]'::JSON
    )
  ) INTO resultado;
  RETURN resultado;
END;
$$;

ALTER FUNCTION public.bot_mis_ventas(UUID, DATE, DATE, BIGINT, INT) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.bot_mis_ventas(UUID, DATE, DATE, BIGINT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_mis_ventas(UUID, DATE, DATE, BIGINT, INT) TO service_role;

-- ============================================================================
-- 4. bot_ranking_preventistas_por_producto
-- ============================================================================
CREATE OR REPLACE FUNCTION public.bot_ranking_preventistas_por_producto(
  p_producto_ids BIGINT[],
  p_desde DATE,
  p_hasta DATE,
  p_sucursal_id BIGINT,
  p_limit INT DEFAULT 10
)
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE resultado JSON;
BEGIN
  WITH ventas_filtradas AS (
    SELECT p.usuario_id, pi.producto_id, pi.cantidad, pi.subtotal
    FROM pedidos p
    JOIN pedido_items pi ON pi.pedido_id = p.id
    WHERE p.sucursal_id = p_sucursal_id
      AND p.fecha BETWEEN p_desde AND p_hasta
      AND COALESCE(p.estado, '') NOT IN ('cancelado', 'anulado')
      AND pi.producto_id = ANY(p_producto_ids)
  ),
  por_usuario AS (
    SELECT
      v.usuario_id,
      pf.nombre,
      pf.rol,
      SUM(v.cantidad)               AS unidades,
      SUM(v.subtotal)               AS facturado,
      COUNT(DISTINCT v.producto_id) AS productos_distintos,
      COUNT(*)                      AS line_items
    FROM ventas_filtradas v
    LEFT JOIN perfiles pf ON pf.id = v.usuario_id
    GROUP BY v.usuario_id, pf.nombre, pf.rol
    ORDER BY SUM(v.cantidad) DESC
    LIMIT p_limit
  ),
  productos_info AS (
    SELECT id, codigo, nombre
    FROM productos
    WHERE id = ANY(p_producto_ids)
    ORDER BY id
  )
  SELECT json_build_object(
    'producto_ids', to_json(p_producto_ids),
    'productos', COALESCE(
      (SELECT json_agg(row_to_json(pi.*)) FROM productos_info pi),
      '[]'::JSON
    ),
    'desde', p_desde,
    'hasta', p_hasta,
    'unidades_total', (SELECT COALESCE(SUM(cantidad), 0) FROM ventas_filtradas),
    'facturado_total', (SELECT COALESCE(SUM(subtotal), 0) FROM ventas_filtradas),
    'preventistas_count', (SELECT COUNT(*) FROM por_usuario),
    'preventistas', COALESCE(
      (SELECT json_agg(row_to_json(pu.*)) FROM por_usuario pu),
      '[]'::JSON
    )
  ) INTO resultado;
  RETURN resultado;
END;
$$;

ALTER FUNCTION public.bot_ranking_preventistas_por_producto(BIGINT[], DATE, DATE, BIGINT, INT) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.bot_ranking_preventistas_por_producto(BIGINT[], DATE, DATE, BIGINT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_ranking_preventistas_por_producto(BIGINT[], DATE, DATE, BIGINT, INT) TO service_role;

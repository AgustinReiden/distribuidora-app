-- ============================================================================
-- 098 · Bot: "venta" = venta ENTREGADA (alinear con reporte_gerencial)
-- ============================================================================
-- Bug detectado en auditoría 2026-06-29: los RPC de venta del bot contaban
-- como "venta" cualquier pedido NOT IN ('cancelado','anulado') y sin filtrar
-- canal → sumaban asignado+pendiente (mercadería NO entregada). Junio Tucumán:
-- bot $21,27M vs reporte $18,27M; gap $3,01M = exactamente asignado+pendiente.
--
-- Definición canónica de venta entregada (igual que reporte_gerencial):
--   estado='entregado' AND canal='app'.
--
-- bot_ventas_periodo además expone los pedidos en curso (asignado+pendiente)
-- como cifra SEPARADA (en_curso_*), nunca mezclada con "ventas".
--
-- NOTA: CREATE OR REPLACE preserva owner y permisos (no reintroduce el grant
-- a PUBLIC). Defs basadas en la versión EN VIVO de prod (no en el repo).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- bot_ventas_periodo
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_ventas_periodo(p_desde date, p_hasta date, p_sucursal_id bigint, p_limit integer DEFAULT 10)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE resultado JSON;
BEGIN
  WITH ventas_filtradas AS (
    SELECT id, cliente_id, total, fecha
    FROM pedidos
    WHERE sucursal_id = p_sucursal_id
      AND fecha BETWEEN p_desde AND p_hasta
      AND estado = 'entregado' AND canal = 'app'
  ),
  en_curso AS (
    SELECT COALESCE(SUM(total), 0) AS monto, COUNT(*) AS pedidos
    FROM pedidos
    WHERE sucursal_id = p_sucursal_id
      AND fecha BETWEEN p_desde AND p_hasta
      AND canal = 'app'
      AND COALESCE(estado, '') IN ('asignado', 'pendiente')
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
    'ticket_promedio', (SELECT CASE WHEN COUNT(*) > 0 THEN ROUND(AVG(total), 2) ELSE 0 END FROM ventas_filtradas),
    'en_curso_monto', (SELECT monto FROM en_curso),
    'en_curso_pedidos', (SELECT pedidos FROM en_curso),
    'top_clientes', COALESCE((SELECT json_agg(row_to_json(tc.*)) FROM top_clientes tc), '[]'::JSON),
    'top_productos', COALESCE((SELECT json_agg(row_to_json(tp.*)) FROM top_productos tp), '[]'::JSON)
  ) INTO resultado;
  RETURN resultado;
END;
$function$;

-- ----------------------------------------------------------------------------
-- bot_mis_ventas
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_mis_ventas(p_preventista_id uuid, p_desde date, p_hasta date, p_sucursal_id bigint, p_limit integer DEFAULT 10)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE resultado JSON;
BEGIN
  WITH ventas_filtradas AS (
    SELECT p.id, p.cliente_id, p.total
    FROM pedidos p
    WHERE p.sucursal_id = p_sucursal_id
      AND p.usuario_id  = p_preventista_id
      AND p.fecha BETWEEN p_desde AND p_hasta
      AND p.estado = 'entregado' AND p.canal = 'app'
  ),
  top_clientes AS (
    SELECT c.id AS cliente_id, c.codigo AS cliente_codigo,
      c.nombre_fantasia, c.razon_social,
      SUM(v.total) AS total_comprado, COUNT(*) AS pedidos
    FROM ventas_filtradas v JOIN clientes c ON c.id = v.cliente_id
    GROUP BY c.id, c.codigo, c.nombre_fantasia, c.razon_social
    ORDER BY SUM(v.total) DESC LIMIT p_limit
  )
  SELECT json_build_object(
    'desde', p_desde, 'hasta', p_hasta,
    'preventista_id', p_preventista_id,
    'total_ventas', (SELECT COALESCE(SUM(total), 0) FROM ventas_filtradas),
    'pedidos_count', (SELECT COUNT(*) FROM ventas_filtradas),
    'ticket_promedio', (SELECT CASE WHEN COUNT(*) > 0 THEN ROUND(AVG(total), 2) ELSE 0 END FROM ventas_filtradas),
    'clientes_distintos', (SELECT COUNT(DISTINCT cliente_id) FROM ventas_filtradas),
    'top_clientes', COALESCE((SELECT json_agg(row_to_json(tc.*)) FROM top_clientes tc), '[]'::JSON)
  ) INTO resultado;
  RETURN resultado;
END;
$function$;

-- ----------------------------------------------------------------------------
-- bot_ventas_por_preventista  (sigue agrupando por usuario_id; pasará a
-- vendedor_id en la migración de la Fase 3)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_ventas_por_preventista(p_desde date, p_hasta date, p_sucursal_id bigint, p_solo_preventistas boolean DEFAULT true, p_limit integer DEFAULT 25)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE resultado JSON;
BEGIN
  WITH ventas_filtradas AS (
    SELECT p.id, p.usuario_id, p.total
    FROM pedidos p
    LEFT JOIN perfiles pf ON pf.id = p.usuario_id
    WHERE p.sucursal_id = p_sucursal_id
      AND p.fecha BETWEEN p_desde AND p_hasta
      AND p.estado = 'entregado' AND p.canal = 'app'
      AND (NOT p_solo_preventistas OR pf.rol = 'preventista')
  ),
  por_usuario AS (
    SELECT v.usuario_id, pf.nombre, pf.rol,
           COUNT(*) AS pedidos, SUM(v.total) AS total_vendido,
           ROUND(AVG(v.total), 2) AS ticket_promedio
    FROM ventas_filtradas v LEFT JOIN perfiles pf ON pf.id = v.usuario_id
    GROUP BY v.usuario_id, pf.nombre, pf.rol
    ORDER BY SUM(v.total) DESC LIMIT p_limit
  )
  SELECT json_build_object(
    'desde', p_desde, 'hasta', p_hasta,
    'solo_preventistas', p_solo_preventistas,
    'total_ventas', (SELECT COALESCE(SUM(total), 0) FROM ventas_filtradas),
    'pedidos_count', (SELECT COUNT(*) FROM ventas_filtradas),
    'preventistas_count', (SELECT COUNT(*) FROM por_usuario),
    'preventistas', COALESCE((SELECT json_agg(row_to_json(pu.*)) FROM por_usuario pu), '[]'::JSON)
  ) INTO resultado;
  RETURN resultado;
END;
$function$;

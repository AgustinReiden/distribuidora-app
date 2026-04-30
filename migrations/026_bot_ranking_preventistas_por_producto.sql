-- Migración 026 — Bot Telegram: ranking de preventistas por un producto puntual
--
-- RPC token-eficiente para responder "quién vendió más Manaos 3000 este mes",
-- "top vendedores de aceite girasol", "para darle una bonificación al que más
-- vendió X". Requiere producto_id (el bot lo consigue antes con buscar_producto).
--
-- Diseño: por diseño NO hacemos un cross-tab (preventista × todos los productos)
-- — devolvería tablas inmanejables. La tool fuerza un producto específico.
--
-- Convenciones (calcadas de migrations 022 y 025):
--   * Filtro por created_at (consistente con bot_ventas_periodo / bot_ventas_por_preventista).
--   * Excluye estados 'cancelado' y 'anulado'.
--   * SECURITY DEFINER + grant explícito a service_role.

CREATE OR REPLACE FUNCTION public.bot_ranking_preventistas_por_producto(
  p_producto_id BIGINT,
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
    SELECT p.usuario_id, pi.cantidad, pi.subtotal
    FROM pedidos p
    JOIN pedido_items pi ON pi.pedido_id = p.id
    WHERE p.sucursal_id = p_sucursal_id
      AND p.created_at >= p_desde::TIMESTAMPTZ
      AND p.created_at < (p_hasta::DATE + 1)::TIMESTAMPTZ
      AND COALESCE(p.estado, '') NOT IN ('cancelado', 'anulado')
      AND pi.producto_id = p_producto_id
  ),
  por_usuario AS (
    SELECT
      v.usuario_id,
      pf.nombre,
      pf.rol,
      SUM(v.cantidad)             AS unidades,
      SUM(v.subtotal)             AS facturado,
      COUNT(*)                    AS pedidos_con_producto
    FROM ventas_filtradas v
    LEFT JOIN perfiles pf ON pf.id = v.usuario_id
    GROUP BY v.usuario_id, pf.nombre, pf.rol
    ORDER BY SUM(v.cantidad) DESC
    LIMIT p_limit
  ),
  producto_info AS (
    SELECT id, codigo, nombre
    FROM productos
    WHERE id = p_producto_id
  )
  SELECT json_build_object(
    'producto_id', p_producto_id,
    'producto_codigo', (SELECT codigo FROM producto_info),
    'producto_nombre', (SELECT nombre FROM producto_info),
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

ALTER FUNCTION public.bot_ranking_preventistas_por_producto(BIGINT, DATE, DATE, BIGINT, INT) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.bot_ranking_preventistas_por_producto(BIGINT, DATE, DATE, BIGINT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_ranking_preventistas_por_producto(BIGINT, DATE, DATE, BIGINT, INT) TO service_role;

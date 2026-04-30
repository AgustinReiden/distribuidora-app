-- Migración 027 — Bot Telegram: ranking de preventistas por GRUPO de productos
--
-- Cambio respecto a migration 026: el RPC ahora acepta un ARRAY de productos
-- en vez de uno solo. Permite agrupar (ej: "Manaos 3000cc" puede matchear
-- 3 sabores distintos, cada uno con su propio producto_id; el bot los junta
-- y consulta el ranking agregado).
--
-- Diseño:
--   * El bot encadena: productos_por_categoria("MANAOS", q="3000") → toma
--     los IDs matcheados → ranking_preventistas_por_producto({producto_ids:[...]})
--   * Output incluye `productos`: lista con id+codigo+nombre de los productos
--     considerados, para que el modelo pueda explicar qué incluyó.
--   * Mantiene el resto de las convenciones (created_at, excluye cancelado/anulado,
--     SECURITY DEFINER + grant a service_role).
--
-- Estrategia para evitar window de incompatibilidad: la migration ALTER
-- (drop + create con misma name) corre en una transacción. Hay un breve
-- período entre la apply y el deploy del edge function donde la versión
-- vieja del bot (que pasa p_producto_id singular) no encuentra la firma.
-- Aceptable: tráfico de prod durante esta ventana es ~nulo y la firma
-- vieja era nuestra (deploy de ayer, sin otros consumidores).

DROP FUNCTION IF EXISTS public.bot_ranking_preventistas_por_producto(
  BIGINT, DATE, DATE, BIGINT, INT
);

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
      AND p.created_at >= p_desde::TIMESTAMPTZ
      AND p.created_at < (p_hasta::DATE + 1)::TIMESTAMPTZ
      AND COALESCE(p.estado, '') NOT IN ('cancelado', 'anulado')
      AND pi.producto_id = ANY(p_producto_ids)
  ),
  por_usuario AS (
    SELECT
      v.usuario_id,
      pf.nombre,
      pf.rol,
      SUM(v.cantidad)             AS unidades,
      SUM(v.subtotal)             AS facturado,
      COUNT(DISTINCT v.producto_id) AS productos_distintos,
      COUNT(*)                    AS line_items
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

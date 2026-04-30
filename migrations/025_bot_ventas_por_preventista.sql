-- Migración 025 — Bot Telegram: ventas agregadas por preventista y "mis ventas"
--
-- Agrega dos RPCs para reportes tipo Power BI:
--
--   1. bot_ventas_por_preventista(desde, hasta, sucursal, [solo_preventistas], [limit])
--      Ranking de ventas agrupadas por usuario_id (preventista). Permite responder
--      "ventas de ayer por preventista", "quién vendió más esta semana", etc.
--      `solo_preventistas` filtra por perfiles.rol='preventista' para excluir
--      ventas registradas a nombre de un admin/encargado del mostrador.
--
--   2. bot_mis_ventas(preventista_id, desde, hasta, sucursal)
--      Resumen de las ventas del propio preventista en el período: total, conteo
--      de pedidos, ticket promedio, clientes distintos, top clientes.
--
-- Convenciones tomadas de migration 022 (bot_ventas_periodo):
--   * Filtro por created_at (NO por fecha) — para que los totales matcheen 1:1
--     contra bot_ventas_periodo. Mezclar columnas daría números distintos para
--     la misma pregunta.
--   * Excluye estados 'cancelado' y 'anulado'.
--   * SECURITY DEFINER + grant explícito a service_role; la edge function valida
--     rol y sucursal antes de invocar.

-- ============================================================================
-- 1. bot_ventas_por_preventista
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
      AND p.created_at >= p_desde::TIMESTAMPTZ
      AND p.created_at < (p_hasta::DATE + 1)::TIMESTAMPTZ
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
-- 2. bot_mis_ventas — resumen del propio preventista
-- ============================================================================
-- p_preventista_id es el caller (perfil_id del bot). Como solo se exporta a
-- service_role y la edge function pasa siempre ctx.perfil_id, no hay forma
-- desde el bot de pedir las ventas de OTRO preventista. La edge function
-- valida adicionalmente que rol='preventista' antes de invocar.

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
      AND p.created_at >= p_desde::TIMESTAMPTZ
      AND p.created_at < (p_hasta::DATE + 1)::TIMESTAMPTZ
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

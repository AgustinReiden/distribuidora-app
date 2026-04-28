-- Migración 023 — Bot Telegram: RPCs para preventista y transportista
--
-- Cierra la iteración 2 con tools que cubren el día-a-día de los roles
-- operativos:
--   * Preventista: histórico de pedidos de un cliente + productos
--     recurrentes (drill-down de la ficha que ya existe).
--   * Transportista: resumen del día (cobrado vs facturado).
--
-- Patrón calcado de migrations 015 y 022: SECURITY DEFINER, GRANT solo a
-- service_role. Las RPCs de cliente exigen el mismo gate de scope que
-- bot_buscar_cliente (preventista solo ve sus asignados via
-- cliente_preventistas).

-- ============================================================================
-- 1. bot_historico_pedidos_cliente
-- ============================================================================
-- Últimos N pedidos del cliente en los últimos M días, con items resumidos
-- (ARRAY de "<cantidad>x <nombre>"). Útil para que el preventista ofrezca
-- "lo de siempre" o detecte cambios de patrón.

CREATE OR REPLACE FUNCTION public.bot_historico_pedidos_cliente(
  p_cliente_id BIGINT,
  p_perfil_id UUID,
  p_rol TEXT,
  p_sucursal_id BIGINT,
  p_dias INT DEFAULT 90,
  p_limit INT DEFAULT 20
)
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE resultado JSON;
BEGIN
  -- Defense-in-depth: si rol=preventista, validamos que el cliente esté
  -- asignado al preventista que invoca. Sin este check, un preventista
  -- podría pasar cualquier cliente_id y leer pedidos ajenos.
  IF p_rol = 'preventista' THEN
    IF NOT EXISTS(
      SELECT 1 FROM cliente_preventistas
      WHERE cliente_id = p_cliente_id AND preventista_id = p_perfil_id
    ) THEN
      RETURN json_build_object(
        'cliente_id', p_cliente_id,
        'pedidos_count', 0,
        'pedidos', '[]'::JSON,
        'error', 'Cliente no asignado a este preventista'
      );
    END IF;
  END IF;

  WITH ultimos_pedidos AS (
    SELECT id, fecha, total, estado, estado_pago, created_at
    FROM pedidos
    WHERE cliente_id = p_cliente_id
      AND sucursal_id = p_sucursal_id
      AND created_at > now() - (p_dias || ' days')::INTERVAL
      AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
    ORDER BY created_at DESC
    LIMIT p_limit
  ),
  pedidos_con_items AS (
    SELECT
      up.id, up.fecha, up.total, up.estado, up.estado_pago, up.created_at,
      (
        SELECT json_agg(
          json_build_object(
            'producto_id', p.id,
            'codigo', p.codigo,
            'nombre', p.nombre,
            'cantidad', pi.cantidad,
            'subtotal', pi.subtotal
          )
          ORDER BY pi.subtotal DESC
        )
        FROM pedido_items pi
        JOIN productos p ON p.id = pi.producto_id
        WHERE pi.pedido_id = up.id
      ) AS items
    FROM ultimos_pedidos up
  )
  SELECT json_build_object(
    'cliente_id', p_cliente_id,
    'pedidos_count', (SELECT COUNT(*) FROM pedidos_con_items),
    'rango_dias', p_dias,
    'total_periodo', (SELECT COALESCE(SUM(total), 0) FROM pedidos_con_items),
    'pedidos', COALESCE(
      (SELECT json_agg(row_to_json(p.*) ORDER BY p.created_at DESC) FROM pedidos_con_items p),
      '[]'::JSON
    )
  ) INTO resultado;
  RETURN resultado;
END;
$$;

ALTER FUNCTION public.bot_historico_pedidos_cliente(BIGINT, UUID, TEXT, BIGINT, INT, INT) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.bot_historico_pedidos_cliente(BIGINT, UUID, TEXT, BIGINT, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_historico_pedidos_cliente(BIGINT, UUID, TEXT, BIGINT, INT, INT) TO service_role;

-- ============================================================================
-- 2. bot_productos_recurrentes_cliente
-- ============================================================================
-- Top productos que el cliente compra más seguido, en los últimos M días.
-- Ordenado por cantidad de pedidos donde aparece el producto (no por unidades
-- totales — un cliente que pidió 100 unidades una vez no es "recurrente").

CREATE OR REPLACE FUNCTION public.bot_productos_recurrentes_cliente(
  p_cliente_id BIGINT,
  p_perfil_id UUID,
  p_rol TEXT,
  p_sucursal_id BIGINT,
  p_dias INT DEFAULT 90,
  p_limit INT DEFAULT 10
)
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE resultado JSON;
BEGIN
  -- Mismo gate que historico_pedidos.
  IF p_rol = 'preventista' THEN
    IF NOT EXISTS(
      SELECT 1 FROM cliente_preventistas
      WHERE cliente_id = p_cliente_id AND preventista_id = p_perfil_id
    ) THEN
      RETURN json_build_object(
        'cliente_id', p_cliente_id,
        'productos', '[]'::JSON,
        'error', 'Cliente no asignado a este preventista'
      );
    END IF;
  END IF;

  WITH items_periodo AS (
    SELECT pi.producto_id, pi.cantidad, pi.subtotal, pe.id AS pedido_id
    FROM pedido_items pi
    JOIN pedidos pe ON pe.id = pi.pedido_id
    WHERE pe.cliente_id = p_cliente_id
      AND pe.sucursal_id = p_sucursal_id
      AND pe.created_at > now() - (p_dias || ' days')::INTERVAL
      AND COALESCE(pe.estado, '') NOT IN ('cancelado', 'anulado')
  ),
  ranked AS (
    SELECT
      p.id, p.codigo, p.nombre, p.precio,
      COUNT(DISTINCT ip.pedido_id) AS pedidos_con_producto,
      SUM(ip.cantidad) AS unidades_totales,
      SUM(ip.subtotal) AS facturado_total
    FROM items_periodo ip
    JOIN productos p ON p.id = ip.producto_id
    GROUP BY p.id, p.codigo, p.nombre, p.precio
    ORDER BY COUNT(DISTINCT ip.pedido_id) DESC, SUM(ip.cantidad) DESC
    LIMIT p_limit
  )
  SELECT json_build_object(
    'cliente_id', p_cliente_id,
    'rango_dias', p_dias,
    'productos', COALESCE(
      (SELECT json_agg(row_to_json(r.*)) FROM ranked r),
      '[]'::JSON
    )
  ) INTO resultado;
  RETURN resultado;
END;
$$;

ALTER FUNCTION public.bot_productos_recurrentes_cliente(BIGINT, UUID, TEXT, BIGINT, INT, INT) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.bot_productos_recurrentes_cliente(BIGINT, UUID, TEXT, BIGINT, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_productos_recurrentes_cliente(BIGINT, UUID, TEXT, BIGINT, INT, INT) TO service_role;

-- ============================================================================
-- 3. bot_recorrido_resumen
-- ============================================================================
-- Recap del día para el transportista. La tabla `recorridos` ya tiene los
-- agregados pre-computados (total_pedidos, pedidos_entregados,
-- total_facturado, total_cobrado), así que el RPC es básicamente un SELECT.
-- Si no hay recorrido para esa fecha, devuelve null.

CREATE OR REPLACE FUNCTION public.bot_recorrido_resumen(
  p_transportista_id UUID,
  p_sucursal_id BIGINT,
  p_fecha DATE DEFAULT CURRENT_DATE
)
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE resultado JSON;
BEGIN
  SELECT json_build_object(
    'recorrido_id', r.id,
    'fecha', r.fecha,
    'estado', r.estado,
    'total_pedidos', r.total_pedidos,
    'pedidos_entregados', r.pedidos_entregados,
    'pedidos_pendientes', GREATEST(r.total_pedidos - r.pedidos_entregados, 0),
    'total_facturado', r.total_facturado,
    'total_cobrado', r.total_cobrado,
    'porcentaje_cobrado', CASE
      WHEN r.total_facturado > 0 THEN ROUND((r.total_cobrado / r.total_facturado) * 100, 1)
      ELSE 0
    END,
    'completed_at', r.completed_at
  ) INTO resultado
  FROM recorridos r
  WHERE r.transportista_id = p_transportista_id
    AND r.sucursal_id = p_sucursal_id
    AND r.fecha = p_fecha;

  -- NULL si no hay recorrido para esa fecha. La tool TS lo interpreta y
  -- responde "no tenés recorrido cargado para hoy".
  RETURN resultado;
END;
$$;

ALTER FUNCTION public.bot_recorrido_resumen(UUID, BIGINT, DATE) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.bot_recorrido_resumen(UUID, BIGINT, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_recorrido_resumen(UUID, BIGINT, DATE) TO service_role;

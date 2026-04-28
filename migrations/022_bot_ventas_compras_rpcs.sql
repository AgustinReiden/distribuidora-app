-- Migración 022 — Bot Telegram: RPCs de ventas y compras
--
-- Este iteración agrega 4 RPCs para que el bot pueda responder consultas
-- agregadas tipo "¿cuánto vendí este mes?", "¿quiénes me deben más?",
-- "¿qué le compré a Coca-Cola?", "¿qué pagos recibí del cliente X?".
--
-- Las tablas pedidos / pedido_items / pagos / compras / compra_items /
-- proveedores YA existen con data real (1210 pedidos, 48 compras, 14
-- proveedores). Solo agregamos lectura agregada — sin cambios al schema.
--
-- Patrón de seguridad calcado de migration 015: SECURITY DEFINER, GRANT
-- solo a service_role. La edge function valida rol/sucursal antes de
-- invocar.
--
-- NOTA: el campo `compras.estado` en prod tiene 'recibida' o 'cancelada'.
-- No hay tracking explícito de pagado/pendiente para compras a proveedores.
-- Si en el futuro hace falta "deuda con proveedores", se modela en una
-- migration aparte.

-- ============================================================================
-- 1. bot_ventas_periodo: top productos + top clientes + total ventas
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
    SELECT id, cliente_id, total, created_at
    FROM pedidos
    WHERE sucursal_id = p_sucursal_id
      AND created_at >= p_desde::TIMESTAMPTZ
      AND created_at < (p_hasta::DATE + 1)::TIMESTAMPTZ
      AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
  ),
  top_clientes AS (
    SELECT
      c.id, c.codigo, c.nombre_fantasia, c.razon_social,
      SUM(v.total) AS total_comprado,
      COUNT(*) AS pedidos
    FROM ventas_filtradas v
    JOIN clientes c ON c.id = v.cliente_id
    GROUP BY c.id, c.codigo, c.nombre_fantasia, c.razon_social
    ORDER BY SUM(v.total) DESC
    LIMIT p_limit
  ),
  top_productos AS (
    SELECT
      p.id, p.codigo, p.nombre,
      SUM(pi.cantidad) AS unidades,
      SUM(pi.subtotal) AS facturado
    FROM ventas_filtradas v
    JOIN pedido_items pi ON pi.pedido_id = v.id
    JOIN productos p ON p.id = pi.producto_id
    GROUP BY p.id, p.codigo, p.nombre
    ORDER BY SUM(pi.subtotal) DESC
    LIMIT p_limit
  )
  SELECT json_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'total_ventas', (SELECT COALESCE(SUM(total), 0) FROM ventas_filtradas),
    'pedidos_count', (SELECT COUNT(*) FROM ventas_filtradas),
    'ticket_promedio', (
      SELECT CASE WHEN COUNT(*) > 0 THEN ROUND(AVG(total), 2) ELSE 0 END
      FROM ventas_filtradas
    ),
    'top_clientes', COALESCE(
      (SELECT json_agg(row_to_json(tc.*)) FROM top_clientes tc),
      '[]'::JSON
    ),
    'top_productos', COALESCE(
      (SELECT json_agg(row_to_json(tp.*)) FROM top_productos tp),
      '[]'::JSON
    )
  ) INTO resultado;
  RETURN resultado;
END;
$$;

ALTER FUNCTION public.bot_ventas_periodo(DATE, DATE, BIGINT, INT) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.bot_ventas_periodo(DATE, DATE, BIGINT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_ventas_periodo(DATE, DATE, BIGINT, INT) TO service_role;

-- ============================================================================
-- 2. bot_pendientes_pago: clientes con pedidos no pagados
-- ============================================================================
-- Devuelve los pedidos con estado_pago != 'pagado' del cliente, agrupado.
-- Ordena por días desde el pedido más viejo (cabeza primero).
-- p_dias_atraso: si > 0, solo muestra pedidos con más de N días.

CREATE OR REPLACE FUNCTION public.bot_pendientes_pago(
  p_sucursal_id BIGINT,
  p_dias_atraso INT DEFAULT 0,
  p_limit INT DEFAULT 50
)
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE resultado JSON;
BEGIN
  WITH pendientes AS (
    SELECT
      c.id AS cliente_id,
      c.codigo AS cliente_codigo,
      c.nombre_fantasia,
      c.razon_social,
      COUNT(p.id) AS pedidos_pendientes,
      SUM(p.total) AS total_adeudado,
      MIN(p.created_at)::DATE AS pedido_mas_viejo,
      EXTRACT(DAY FROM now() - MIN(p.created_at))::INT AS dias_max_atraso
    FROM pedidos p
    JOIN clientes c ON c.id = p.cliente_id
    WHERE p.sucursal_id = p_sucursal_id
      AND COALESCE(p.estado_pago, 'pendiente') <> 'pagado'
      AND COALESCE(p.estado, '') NOT IN ('cancelado', 'anulado')
    GROUP BY c.id, c.codigo, c.nombre_fantasia, c.razon_social
    HAVING EXTRACT(DAY FROM now() - MIN(MIN(p.created_at))) >= p_dias_atraso
        OR p_dias_atraso = 0
  )
  SELECT json_build_object(
    'sucursal_id', p_sucursal_id,
    'dias_atraso_min', p_dias_atraso,
    'total_global', (SELECT COALESCE(SUM(total_adeudado), 0) FROM pendientes),
    'clientes_count', (SELECT COUNT(*) FROM pendientes),
    'clientes', COALESCE(
      (SELECT json_agg(row_to_json(p.*) ORDER BY p.dias_max_atraso DESC)
       FROM (SELECT * FROM pendientes ORDER BY dias_max_atraso DESC LIMIT p_limit) p),
      '[]'::JSON
    )
  ) INTO resultado;
  RETURN resultado;
END;
$$;

ALTER FUNCTION public.bot_pendientes_pago(BIGINT, INT, INT) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.bot_pendientes_pago(BIGINT, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_pendientes_pago(BIGINT, INT, INT) TO service_role;

-- ============================================================================
-- 3. bot_historico_pagos_cliente: últimos N pagos del cliente
-- ============================================================================

CREATE OR REPLACE FUNCTION public.bot_historico_pagos_cliente(
  p_cliente_id BIGINT,
  p_sucursal_id BIGINT,
  p_limit INT DEFAULT 20
)
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE resultado JSON;
BEGIN
  WITH ultimos_pagos AS (
    SELECT
      pg.id, pg.monto, pg.forma_pago, pg.fecha,
      pg.referencia, pg.notas, pg.pedido_id
    FROM pagos pg
    WHERE pg.cliente_id = p_cliente_id
      AND pg.sucursal_id = p_sucursal_id
    ORDER BY pg.fecha DESC, pg.id DESC
    LIMIT p_limit
  )
  SELECT json_build_object(
    'cliente_id', p_cliente_id,
    'pagos_count', (SELECT COUNT(*) FROM ultimos_pagos),
    'total_ultimos', (SELECT COALESCE(SUM(monto), 0) FROM ultimos_pagos),
    'pagos', COALESCE(
      (SELECT json_agg(row_to_json(up.*)) FROM ultimos_pagos up),
      '[]'::JSON
    )
  ) INTO resultado;
  RETURN resultado;
END;
$$;

ALTER FUNCTION public.bot_historico_pagos_cliente(BIGINT, BIGINT, INT) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.bot_historico_pagos_cliente(BIGINT, BIGINT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_historico_pagos_cliente(BIGINT, BIGINT, INT) TO service_role;

-- ============================================================================
-- 4. bot_compras_periodo: total compras + top proveedores en un rango
-- ============================================================================
-- Filtra por compras.fecha_compra (no created_at) — refleja la fecha real
-- en que se hizo la compra, no cuándo se cargó al sistema. Excluye
-- compras canceladas (estado='cancelada').

CREATE OR REPLACE FUNCTION public.bot_compras_periodo(
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
  WITH compras_filtradas AS (
    SELECT id, proveedor_id, proveedor_nombre, total, fecha_compra
    FROM compras
    WHERE sucursal_id = p_sucursal_id
      AND fecha_compra >= p_desde
      AND fecha_compra <= p_hasta
      AND COALESCE(estado, '') <> 'cancelada'
  ),
  top_proveedores AS (
    SELECT
      cf.proveedor_id,
      COALESCE(pr.nombre, cf.proveedor_nombre, 'Sin nombre') AS nombre,
      pr.cuit,
      SUM(cf.total) AS total_comprado,
      COUNT(*) AS compras_count
    FROM compras_filtradas cf
    LEFT JOIN proveedores pr ON pr.id = cf.proveedor_id
    GROUP BY cf.proveedor_id, pr.nombre, cf.proveedor_nombre, pr.cuit
    ORDER BY SUM(cf.total) DESC
    LIMIT p_limit
  )
  SELECT json_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'total_compras', (SELECT COALESCE(SUM(total), 0) FROM compras_filtradas),
    'compras_count', (SELECT COUNT(*) FROM compras_filtradas),
    'top_proveedores', COALESCE(
      (SELECT json_agg(row_to_json(tp.*)) FROM top_proveedores tp),
      '[]'::JSON
    )
  ) INTO resultado;
  RETURN resultado;
END;
$$;

ALTER FUNCTION public.bot_compras_periodo(DATE, DATE, BIGINT, INT) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.bot_compras_periodo(DATE, DATE, BIGINT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_compras_periodo(DATE, DATE, BIGINT, INT) TO service_role;

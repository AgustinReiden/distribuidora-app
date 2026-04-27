-- Migración 015 - Bot Telegram Phase 2: RPCs específicas para el bot
--
-- Las edge functions del bot corren con service_role (sin JWT de usuario), por
-- lo que `auth.uid()` adentro de las RPCs es NULL. La RPC original
-- `obtener_resumen_cuenta_cliente` (definida en 000_baseline.sql) tiene un
-- guard `IF auth.uid() IS NULL` que retorna `{error: 'No autenticado'}` y, por
-- ende, no funciona desde el bot.
--
-- Esta migración agrega una variante `_bot` con la MISMA lógica de SUMs/MAX
-- pero SIN la check de auth.uid(). El control de acceso al cliente (rol del
-- usuario, sucursal, asignación N-N preventista↔cliente) ya está hecho a
-- nivel edge function en `_shared/tools/common/ficha_cliente.ts` ANTES de
-- llamar este RPC. La función NO debe usarse desde el frontend con auth real:
-- el frontend sigue llamando a la versión original (`obtener_resumen_cuenta_cliente`)
-- que sí valida auth.uid().
--
-- Por eso REVOKE FROM PUBLIC y solo GRANT EXECUTE TO service_role.

-- ============================================================================
-- 1. obtener_resumen_cuenta_cliente_bot — variante service_role-only
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_resumen_cuenta_cliente_bot(p_cliente_id INTEGER)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  resultado JSON;
BEGIN
  -- IMPORTANTE: NO chequear auth.uid() acá. El gate de acceso ya lo hizo la
  -- edge function antes de invocar este RPC: validó el bot_usuarios activo,
  -- el rol, la sucursal y, si aplica, la asignación cliente_preventistas.
  -- Llamar este RPC desde un contexto distinto al bot service_role es un
  -- bypass de seguridad, por eso revocamos PUBLIC más abajo.

  SELECT json_build_object(
    'saldo_actual', COALESCE(c.saldo_cuenta, 0),
    'limite_credito', COALESCE(c.limite_credito, 0),
    'credito_disponible', COALESCE(c.limite_credito, 0) - COALESCE(c.saldo_cuenta, 0),
    'total_pedidos', (SELECT COUNT(*) FROM pedidos WHERE cliente_id = p_cliente_id),
    'total_compras', (SELECT COALESCE(SUM(total), 0) FROM pedidos WHERE cliente_id = p_cliente_id),
    'total_pagos', (SELECT COALESCE(SUM(monto), 0) FROM pagos WHERE cliente_id = p_cliente_id),
    'pedidos_pendientes_pago', (SELECT COUNT(*) FROM pedidos WHERE cliente_id = p_cliente_id AND estado_pago != 'pagado'),
    'ultimo_pedido', (SELECT MAX(created_at) FROM pedidos WHERE cliente_id = p_cliente_id),
    'ultimo_pago', (SELECT MAX(created_at) FROM pagos WHERE cliente_id = p_cliente_id)
  ) INTO resultado
  FROM clientes c
  WHERE c.id = p_cliente_id;

  RETURN resultado;
END;
$$;

ALTER FUNCTION public.obtener_resumen_cuenta_cliente_bot(INTEGER) OWNER TO postgres;

REVOKE ALL    ON FUNCTION public.obtener_resumen_cuenta_cliente_bot(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_resumen_cuenta_cliente_bot(INTEGER) TO service_role;

COMMENT ON FUNCTION public.obtener_resumen_cuenta_cliente_bot(INTEGER) IS
  'Variante de obtener_resumen_cuenta_cliente para uso exclusivo del bot Telegram. Idéntica lógica de SUMs/MAX pero SIN el guard auth.uid() — las edge functions del bot corren con service_role y no tienen JWT, así que la versión original siempre falla. El control de acceso al cliente (bot_usuarios, rol, sucursal, cliente_preventistas) ya lo hace la edge function antes de invocar este RPC. NO usar desde el frontend con auth real: usar obtener_resumen_cuenta_cliente.';

-- ============================================================================
-- 2. bot_mis_clientes — cartera de clientes asignados a un preventista
-- ============================================================================
--
-- Devuelve los clientes asignados al preventista (vía cliente_preventistas)
-- en la sucursal indicada, opcionalmente filtrados por:
--   * con_deuda = TRUE   → solo clientes con saldo_cuenta > 0
--   * sin_pedidos_dias N → solo clientes que NO tienen pedidos no-cancelados
--                          en los últimos N días (incluye los que nunca
--                          compraron)
--
-- Cada cliente incluye `ultima_compra` (MAX(fecha) sobre pedidos no-cancelados)
-- y `dias_desde_ultima` (CURRENT_DATE - ultima_compra::date), null si nunca
-- compró.
--
-- Como `obtener_resumen_cuenta_cliente_bot`, esta RPC es service_role-only:
-- el control de acceso (rol, sucursal, perfil_id del caller) ya lo hizo la
-- edge function antes de invocarla.

CREATE OR REPLACE FUNCTION public.bot_mis_clientes(
  p_preventista_id UUID,
  p_sucursal_id    BIGINT,
  p_con_deuda      BOOLEAN DEFAULT FALSE,
  p_sin_pedidos_dias INTEGER DEFAULT NULL,
  p_limit          INTEGER DEFAULT 20
) RETURNS JSON
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH base AS (
    SELECT
      c.id,
      c.codigo,
      c.nombre_fantasia,
      c.razon_social,
      c.saldo_cuenta,
      c.zona,
      (
        SELECT MAX(p.fecha)
        FROM pedidos p
        WHERE p.cliente_id = c.id
          AND p.estado <> 'cancelado'
      ) AS ultima_compra
    FROM clientes c
    JOIN cliente_preventistas cp ON cp.cliente_id = c.id
    WHERE cp.preventista_id = p_preventista_id
      AND c.sucursal_id = p_sucursal_id
      AND c.activo = TRUE
      AND (NOT p_con_deuda OR c.saldo_cuenta > 0)
  ),
  filtrado AS (
    SELECT
      b.*,
      CASE
        WHEN b.ultima_compra IS NULL THEN NULL
        ELSE (CURRENT_DATE - b.ultima_compra::date)
      END AS dias_desde_ultima
    FROM base b
    WHERE p_sin_pedidos_dias IS NULL
       OR b.ultima_compra IS NULL
       OR (CURRENT_DATE - b.ultima_compra::date) >= p_sin_pedidos_dias
  ),
  paged AS (
    SELECT *
    FROM filtrado
    ORDER BY nombre_fantasia ASC NULLS LAST, id ASC
    LIMIT p_limit
  )
  SELECT json_build_object(
    'total', (SELECT COUNT(*) FROM filtrado),
    'clientes', COALESCE(
      (SELECT json_agg(row_to_json(p)) FROM paged p),
      '[]'::json
    )
  );
$$;

ALTER FUNCTION public.bot_mis_clientes(UUID, BIGINT, BOOLEAN, INTEGER, INTEGER) OWNER TO postgres;

REVOKE ALL    ON FUNCTION public.bot_mis_clientes(UUID, BIGINT, BOOLEAN, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_mis_clientes(UUID, BIGINT, BOOLEAN, INTEGER, INTEGER) TO service_role;

COMMENT ON FUNCTION public.bot_mis_clientes(UUID, BIGINT, BOOLEAN, INTEGER, INTEGER) IS
  'Cartera de clientes asignados a un preventista en una sucursal. Incluye saldo_cuenta, ultima_compra y dias_desde_ultima. Filtros opcionales: con_deuda (saldo_cuenta > 0) y sin_pedidos_dias (rotación lenta). Service_role-only: el control de rol/sucursal lo hace la edge function antes de invocar.';

-- ============================================================================
-- 3. bot_mi_recorrido — recorrido del día de un transportista + paradas
-- ============================================================================
--
-- Devuelve el recorrido del día (el más reciente si hay varios) para el
-- transportista indicado en la sucursal indicada, junto con la lista de
-- pedidos asociados (recorrido_pedidos) ordenados por orden_entrega.
--
-- Si no hay recorrido para esa fecha → retorna {recorrido: null, pedidos: []}.
--
-- Como las otras RPCs `bot_*`, es service_role-only.

CREATE OR REPLACE FUNCTION public.bot_mi_recorrido(
  p_transportista_id UUID,
  p_sucursal_id      BIGINT,
  p_fecha            DATE DEFAULT CURRENT_DATE
) RETURNS JSON
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH r AS (
    SELECT
      id,
      fecha::text AS fecha,
      estado,
      total_pedidos,
      pedidos_entregados,
      total_facturado,
      total_cobrado
    FROM recorridos
    WHERE transportista_id = p_transportista_id
      AND fecha = p_fecha
      AND sucursal_id = p_sucursal_id
    ORDER BY id DESC
    LIMIT 1
  )
  SELECT json_build_object(
    'recorrido', COALESCE((SELECT row_to_json(r.*) FROM r), 'null'::json),
    'pedidos', COALESCE(
      (
        SELECT json_agg(
          json_build_object(
            'pedido_id',      rp.pedido_id,
            'orden_entrega',  rp.orden_entrega,
            'estado_entrega', rp.estado_entrega,
            'cliente_id',     p.cliente_id,
            'cliente_nombre', COALESCE(c.nombre_fantasia, c.razon_social, '(sin nombre)'),
            'direccion',      c.direccion,
            'total',          p.total,
            'estado_pago',    p.estado_pago
          )
          ORDER BY rp.orden_entrega ASC NULLS LAST, rp.id ASC
        )
        FROM recorrido_pedidos rp
        JOIN pedidos p ON p.id = rp.pedido_id
        LEFT JOIN clientes c ON c.id = p.cliente_id
        WHERE rp.recorrido_id = (SELECT id FROM r)
      ),
      '[]'::json
    )
  );
$$;

ALTER FUNCTION public.bot_mi_recorrido(UUID, BIGINT, DATE) OWNER TO postgres;

REVOKE ALL    ON FUNCTION public.bot_mi_recorrido(UUID, BIGINT, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_mi_recorrido(UUID, BIGINT, DATE) TO service_role;

COMMENT ON FUNCTION public.bot_mi_recorrido(UUID, BIGINT, DATE) IS
  'Recorrido del día (o fecha indicada) para un transportista en una sucursal, con la lista de pedidos a entregar (cliente, dirección, total, estado_pago, orden_entrega). Si hay múltiples recorridos para esa fecha, retorna el más reciente. Service_role-only: el control de rol/sucursal lo hace la edge function antes de invocar.';

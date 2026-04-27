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

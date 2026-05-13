-- ============================================================================
-- 047 — Habilitar RLS en bot_pedidos_pendientes
-- ============================================================================
-- Cierra el alerta CRITICAL del Supabase Advisor (rls_disabled_in_public)
-- sobre la unica tabla del schema public que estaba expuesta sin RLS.
--
-- La tabla es un buffer efimero del bot Telegram: la edge function inserta
-- un pedido tentativo (perfil_id, cliente_id, items, totales) con TTL 10
-- min y luego lo consume cuando el preventista confirma desde el chat.
--
-- Quien la accede:
--   - Edge function "telegram-webhook" (supabase/functions): usa el cliente
--     service_role (getServiceRoleClient) tanto para INSERT (en
--     previsualizar_pedido.ts) como para UPDATE (handlers.ts L913-918,
--     callback Cancelar). service_role tiene BYPASSRLS → no afectado.
--   - RPC public.crear_pedido_completo_bot: SECURITY DEFINER → corre como
--     dueno de la funcion (postgres), no afectado por RLS.
--   - Frontend / supabase-js como anon o authenticated: NUNCA debe leer
--     ni escribir esta tabla. Hoy estaba abierta, lo cual era el bug.
--
-- Estrategia: ENABLE RLS sin agregar policies. Por default, sin policy
-- los roles anon y authenticated quedan denegados; service_role y
-- SECURITY DEFINER funcs conservan su acceso normal. Es exactamente lo
-- que queremos.
--
-- (El Supabase Advisor puede listar la tabla en el lint INFO
-- "rls_enabled_no_policy" — eso es ruido informativo, no vulnerabilidad.
-- Documentamos la intencion en el COMMENT abajo.)
-- ============================================================================

ALTER TABLE public.bot_pedidos_pendientes ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.bot_pedidos_pendientes IS
  'Buffer efimero del bot Telegram (TTL 10 min). Solo accesible via service_role (edge function) y SECURITY DEFINER RPCs (crear_pedido_completo_bot). RLS habilitado sin policies intencionalmente — anon/authenticated no deben verla.';

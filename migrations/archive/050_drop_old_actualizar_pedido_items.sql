-- Migration 050: Drop old actualizar_pedido_items overload
--
-- La migración 046 creó una nueva versión con 6 params (p_tipo_factura, p_total_neto, p_total_iva)
-- pero no dropeó la versión vieja con 3 params. Supabase no puede resolver la ambigüedad
-- cuando se llama con los 3 params obligatorios + defaults opcionales.

DROP FUNCTION IF EXISTS public.actualizar_pedido_items(bigint, jsonb, uuid);

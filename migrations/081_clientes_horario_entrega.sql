-- Migración 081: horario de entrega preferido del cliente
--
-- Franja horaria en la que el cliente pide recibir el pedido. La completan
-- preventistas/admin en la ficha del cliente y se imprime en la hoja de ruta.
-- Editable por preventistas: NO se agrega al blacklist del trigger
-- clientes_guard_update_preventista (mig 080).
--
-- Aplicada en prod el 2026-06-11 vía MCP (apply_migration: clientes_horario_entrega).

ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS horario_entrega text;

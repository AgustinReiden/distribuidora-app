-- =========================================================================
-- 040_perfiles_rol_check_encargado.sql
--
-- El CHECK constraint perfiles_rol_check quedo desactualizado: solo permite
-- 'admin', 'preventista', 'transportista'. Cuando se agrego 'encargado' (y
-- 'deposito' antes), el constraint no fue refrescado y ahora bloquea editar
-- usuarios a esos roles con:
--   ERROR: new row for relation "perfiles" violates check constraint
--          "perfiles_rol_check"
--
-- Reemplazamos el constraint con la lista completa de roles del enum
-- RolUsuario (src/types/index.ts) y BotRol (supabase/functions/_shared/types.ts).
-- =========================================================================

BEGIN;

ALTER TABLE public.perfiles DROP CONSTRAINT IF EXISTS perfiles_rol_check;

ALTER TABLE public.perfiles
  ADD CONSTRAINT perfiles_rol_check
  CHECK (rol = ANY (ARRAY['admin', 'preventista', 'transportista', 'deposito', 'encargado']::text[]));

COMMIT;

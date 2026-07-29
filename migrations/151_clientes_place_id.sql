-- =========================================================================
-- 151_clientes_place_id.sql
--
-- El caso Chacabuco / Batalla de Chacabuco es ambigüedad legítima: las dos
-- calles existen y Google elige una. No hay solución completa; lo que sí se
-- puede es dejar de perder la evidencia de qué eligió el preventista.
--
-- Hoy `AddressAutocomplete` recibe el `place_id` de Google y lo descarta. Con
-- la columna, cuando un cliente aparezca con la dirección equivocada se puede
-- ir al lugar exacto que se seleccionó, en vez de discutir sobre un texto que
-- puede haberse editado después.
--
-- Nullable y sin backfill posible: los clientes ya cargados no dejaron rastro.
-- =========================================================================

ALTER TABLE public.clientes
  ADD COLUMN IF NOT EXISTS place_id text;

COMMENT ON COLUMN public.clientes.place_id IS
  'Google Places place_id del lugar elegido en el autocompletado. Auditoria de direcciones ambiguas. NULL = cargado antes de la mig 151 o a mano.';

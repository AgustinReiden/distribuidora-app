-- 006_mayorista_escala_minimos_id.sql
--
-- Bugfix: el trigger genérico `audit_log_changes` del sistema accede a
-- NEW.id y OLD.id directamente (no via to_jsonb), lo cual falla con
-- "record \"new\" has no field \"id\"" en tablas de PK compuesta como
-- `grupo_precio_escala_minimos`. Resultado: INSERT/UPDATE/DELETE fallan
-- con 400 desde el frontend.
--
-- Fix minimo: agregar columna `id` BIGSERIAL con UNIQUE (manteniendo la
-- PK compuesta existente como identidad logica de la fila). Asi la funcion
-- de audit encuentra el campo sin tocar su implementacion compartida con
-- el resto de las tablas.

BEGIN;

ALTER TABLE public.grupo_precio_escala_minimos
  ADD COLUMN IF NOT EXISTS id BIGSERIAL;

-- UNIQUE para consistencia con el resto de tablas auditadas.
-- (No reemplaza la PK compuesta, solo garantiza unicidad tecnica del id.)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'grupo_precio_escala_minimos_id_key'
      AND conrelid = 'public.grupo_precio_escala_minimos'::regclass
  ) THEN
    ALTER TABLE public.grupo_precio_escala_minimos
      ADD CONSTRAINT grupo_precio_escala_minimos_id_key UNIQUE (id);
  END IF;
END $$;

COMMIT;

-- Migration 035: Fix bonificacion column type to support decimal values (e.g. 0.6%)
-- The column was INTEGER but users enter decimal bonificacion percentages.

ALTER TABLE compra_items ALTER COLUMN bonificacion TYPE NUMERIC USING bonificacion::NUMERIC;

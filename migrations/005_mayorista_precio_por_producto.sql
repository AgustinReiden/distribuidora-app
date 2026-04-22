-- 005_mayorista_precio_por_producto.sql
--
-- Permite que cada producto dentro de una escala combinada tenga su propio
-- precio mayorista. Antes, la escala tenia un unico `precio_unitario` que
-- aplicaba a todos los productos que activaran la escala. Con precios base
-- distintos entre productos del grupo (ej. codito $900 / moñito $1000),
-- usar un mismo precio mayorista no representa bien la promocion combinada.
--
-- Comportamiento:
--   * Si la fila en grupo_precio_escala_minimos tiene precio_unitario_override
--     NOT NULL, ese producto usa ese precio cuando la escala aplica.
--   * Si es NULL, fallback al `precio_unitario` de la escala (como hoy).
--
-- Retrocompat total: la columna es nullable con default NULL, asi que todas
-- las filas existentes siguen comportandose igual.

BEGIN;

ALTER TABLE public.grupo_precio_escala_minimos
  ADD COLUMN IF NOT EXISTS precio_unitario_override NUMERIC(12,2)
    CHECK (precio_unitario_override IS NULL OR precio_unitario_override > 0);

COMMENT ON COLUMN public.grupo_precio_escala_minimos.precio_unitario_override IS
  'Precio mayorista especifico para este producto cuando la escala aplica. NULL = usar el precio_unitario de la escala (fallback).';

COMMIT;

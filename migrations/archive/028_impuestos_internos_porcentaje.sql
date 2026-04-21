-- ============================================================================
-- 028: Convertir impuestos_internos de monto fijo a porcentaje
-- ============================================================================
-- El campo impuestos_internos en productos pasa a representar un porcentaje
-- en lugar de un monto fijo. Se estima el % a partir del costo neto existente.
-- ============================================================================

-- Convertir valores existentes: monto fijo → porcentaje estimado
-- Solo para productos que tienen costo_sin_iva > 0 e impuestos_internos > 0
UPDATE productos
SET impuestos_internos = ROUND((impuestos_internos / costo_sin_iva) * 100, 2)
WHERE costo_sin_iva > 0 AND impuestos_internos > 0;

-- Para productos sin costo neto pero con impuestos internos, dejar en 0
-- (no se puede calcular el porcentaje sin base)
UPDATE productos
SET impuestos_internos = 0
WHERE (costo_sin_iva IS NULL OR costo_sin_iva = 0) AND impuestos_internos > 0;

-- Agregar comentario al campo para documentar el cambio
COMMENT ON COLUMN productos.impuestos_internos IS 'Porcentaje de impuestos internos (ej: 5 = 5%). Antes era monto fijo.';

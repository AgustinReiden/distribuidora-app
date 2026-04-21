-- Migración: Agregar campos de código, costos y precios a la tabla productos
-- Fecha: 2026-01-02
-- Descripción: Agrega campos para código de producto, costos de compra (con/sin IVA),
--              impuestos internos y precios de venta (con/sin IVA)

-- ============================================================================
-- INSTRUCCIONES DE USO:
-- 1. Ir a Supabase Dashboard > SQL Editor
-- 2. Copiar y pegar este script completo
-- 3. Ejecutar el script
-- ============================================================================

-- Agregar campo para código del producto (SKU, código interno, etc.)
ALTER TABLE productos
ADD COLUMN IF NOT EXISTS codigo VARCHAR(50);

-- Agregar campos de costos (compra)
ALTER TABLE productos
ADD COLUMN IF NOT EXISTS costo_sin_iva DECIMAL(12,2);

ALTER TABLE productos
ADD COLUMN IF NOT EXISTS costo_con_iva DECIMAL(12,2);

ALTER TABLE productos
ADD COLUMN IF NOT EXISTS impuestos_internos DECIMAL(12,2);

-- Agregar campo de precio sin IVA (el precio actual ya es precio con IVA)
ALTER TABLE productos
ADD COLUMN IF NOT EXISTS precio_sin_iva DECIMAL(12,2);

-- Crear índice para búsqueda por código (opcional pero recomendado)
CREATE INDEX IF NOT EXISTS idx_productos_codigo ON productos(codigo);

-- ============================================================================
-- COMENTARIOS PARA DOCUMENTACIÓN
-- ============================================================================

COMMENT ON COLUMN productos.codigo IS 'Código interno del producto (SKU, código de barras, etc.)';
COMMENT ON COLUMN productos.costo_sin_iva IS 'Costo de compra del producto sin IVA';
COMMENT ON COLUMN productos.costo_con_iva IS 'Costo de compra del producto con IVA incluido';
COMMENT ON COLUMN productos.impuestos_internos IS 'Impuestos internos adicionales (IIBB, etc.)';
COMMENT ON COLUMN productos.precio_sin_iva IS 'Precio de venta al público sin IVA';
-- Nota: El campo "precio" existente representa el precio final con IVA (precio al cliente)

-- ============================================================================
-- VERIFICACIÓN (ejecutar después para confirmar los cambios)
-- ============================================================================

-- Para verificar que se crearon los campos correctamente, ejecutar:
-- SELECT column_name, data_type, is_nullable
-- FROM information_schema.columns
-- WHERE table_name = 'productos'
-- ORDER BY ordinal_position;

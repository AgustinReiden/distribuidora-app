-- Migración 014: Agregar porcentaje IVA en productos y tipo documento en clientes
-- Fecha: 2026-01-09
-- Descripción:
--   1. Agrega campo porcentaje_iva en productos para calcular IVA solo sobre neto
--   2. Agrega campo tipo_documento en clientes para distinguir CUIT/DNI

-- ============================================================================
-- PRODUCTOS: Agregar porcentaje de IVA
-- ============================================================================

-- Campo para porcentaje de IVA (21, 10.5, 0, etc.)
ALTER TABLE productos
ADD COLUMN IF NOT EXISTS porcentaje_iva DECIMAL(5,2) DEFAULT 21;

-- Actualizar comentarios
COMMENT ON COLUMN productos.porcentaje_iva IS 'Porcentaje de IVA aplicable al producto (21, 10.5, 0, etc.)';
COMMENT ON COLUMN productos.impuestos_internos IS 'Impuestos internos (no gravados con IVA)';
COMMENT ON COLUMN productos.costo_sin_iva IS 'Costo neto del producto (sin IVA ni impuestos internos)';
COMMENT ON COLUMN productos.costo_con_iva IS 'Costo total = costo_neto + IVA(sobre neto) + impuestos_internos';

-- ============================================================================
-- CLIENTES: Agregar tipo de documento
-- ============================================================================

-- Campo para tipo de documento (CUIT o DNI)
ALTER TABLE clientes
ADD COLUMN IF NOT EXISTS tipo_documento VARCHAR(4) DEFAULT 'CUIT'
CHECK (tipo_documento IN ('CUIT', 'DNI'));

-- Índice para búsqueda por tipo de documento
CREATE INDEX IF NOT EXISTS idx_clientes_tipo_documento ON clientes(tipo_documento);

-- Comentarios
COMMENT ON COLUMN clientes.tipo_documento IS 'Tipo de documento: CUIT (XX-XXXXXXXX-X) o DNI (formato almacenado: 00-XXXXXXXX-0)';
COMMENT ON COLUMN clientes.cuit IS 'Número de documento. CUIT: formato XX-XXXXXXXX-X, DNI: formato 00-XXXXXXXX-0 (estandarizado a 11 dígitos)';

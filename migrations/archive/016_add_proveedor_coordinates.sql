-- Migración 016: Agregar coordenadas geográficas a proveedores
-- Permite almacenar latitud y longitud para futuras funcionalidades de geolocalización

-- Agregar campos de coordenadas a proveedores
ALTER TABLE proveedores
ADD COLUMN IF NOT EXISTS latitud DECIMAL(10, 8),
ADD COLUMN IF NOT EXISTS longitud DECIMAL(11, 8);

-- Comentarios para documentación
COMMENT ON COLUMN proveedores.latitud IS 'Latitud de la ubicación del proveedor';
COMMENT ON COLUMN proveedores.longitud IS 'Longitud de la ubicación del proveedor';

-- Índice espacial para búsquedas geográficas futuras
CREATE INDEX IF NOT EXISTS idx_proveedores_coords ON proveedores(latitud, longitud);

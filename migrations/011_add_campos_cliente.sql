-- Migración 011: Agregar campos adicionales a clientes
-- Fecha: 2026-01-08
-- Descripción: Agrega CUIT, renombra nombre a razon_social, agrega contacto, horarios_atencion, rubro y notas

-- 1. Agregar campo CUIT (obligatorio para nuevos registros, nullable para existentes)
ALTER TABLE clientes ADD COLUMN IF NOT EXISTS cuit VARCHAR(13);

-- 2. Renombrar campo 'nombre' a 'razon_social'
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'clientes' AND column_name = 'nombre') THEN
        ALTER TABLE clientes RENAME COLUMN nombre TO razon_social;
    END IF;
END $$;

-- 3. Agregar campo contacto (nombre de quien atiende el teléfono)
ALTER TABLE clientes ADD COLUMN IF NOT EXISTS contacto VARCHAR(100);

-- 4. Agregar campo horarios de atención
ALTER TABLE clientes ADD COLUMN IF NOT EXISTS horarios_atencion TEXT;

-- 5. Agregar campo rubro/clasificación del cliente
ALTER TABLE clientes ADD COLUMN IF NOT EXISTS rubro VARCHAR(100);

-- 6. Agregar campo notas para información adicional
ALTER TABLE clientes ADD COLUMN IF NOT EXISTS notas TEXT;

-- Crear índice para búsqueda por CUIT
CREATE INDEX IF NOT EXISTS idx_clientes_cuit ON clientes(cuit);

-- Crear índice para filtrado por rubro
CREATE INDEX IF NOT EXISTS idx_clientes_rubro ON clientes(rubro);

-- Comentarios de documentación
COMMENT ON COLUMN clientes.cuit IS 'CUIT del cliente (formato: XX-XXXXXXXX-X)';
COMMENT ON COLUMN clientes.razon_social IS 'Razón social del cliente (nombre legal)';
COMMENT ON COLUMN clientes.contacto IS 'Nombre de la persona que atiende el teléfono';
COMMENT ON COLUMN clientes.horarios_atencion IS 'Horarios de atención del cliente';
COMMENT ON COLUMN clientes.rubro IS 'Clasificación del cliente (gimnasio, bar, kiosco, etc.)';
COMMENT ON COLUMN clientes.notas IS 'Notas adicionales sobre el cliente';

-- Migración: Agregar coordenadas a clientes
-- Fecha: 2026-01-01
-- Descripción: Agrega campos de latitud y longitud para almacenar las coordenadas
--              obtenidas del autocompletado de direcciones con Google Places API

-- 1. Agregar campos de coordenadas a la tabla clientes
ALTER TABLE clientes
ADD COLUMN IF NOT EXISTS latitud NUMERIC(10, 7),
ADD COLUMN IF NOT EXISTS longitud NUMERIC(10, 7);

-- Comentarios para documentar los nuevos campos
COMMENT ON COLUMN clientes.latitud IS 'Latitud de la dirección del cliente (obtenida de Google Places API)';
COMMENT ON COLUMN clientes.longitud IS 'Longitud de la dirección del cliente (obtenida de Google Places API)';

-- 2. Crear índice espacial para consultas geográficas futuras
-- Esto permitirá búsquedas eficientes por ubicación
CREATE INDEX IF NOT EXISTS idx_clientes_coordenadas ON clientes(latitud, longitud)
WHERE latitud IS NOT NULL AND longitud IS NOT NULL;

-- 3. Opcional: Actualizar las políticas RLS si es necesario
-- (No se requiere cambios ya que usamos los mismos permisos existentes)

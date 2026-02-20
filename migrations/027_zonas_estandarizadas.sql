-- ============================================================================
-- 027: Zonas estandarizadas + múltiples zonas por preventista
-- ============================================================================
-- Crea tabla centralizada de zonas, tabla pivot preventista_zonas,
-- y agrega zona_id a clientes y proveedores.
-- ============================================================================

-- 1. Tabla centralizada de zonas
CREATE TABLE IF NOT EXISTS zonas (
  id BIGSERIAL PRIMARY KEY,
  nombre VARCHAR(100) NOT NULL,
  activo BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT zonas_nombre_unique UNIQUE (nombre)
);

-- RLS
ALTER TABLE zonas ENABLE ROW LEVEL SECURITY;
CREATE POLICY "zonas_select_authenticated" ON zonas
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "zonas_insert_authenticated" ON zonas
  FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "zonas_update_authenticated" ON zonas
  FOR UPDATE TO authenticated USING (true);

-- 2. Tabla pivot: preventista puede tener múltiples zonas
CREATE TABLE IF NOT EXISTS preventista_zonas (
  id BIGSERIAL PRIMARY KEY,
  perfil_id UUID NOT NULL REFERENCES perfiles(id) ON DELETE CASCADE,
  zona_id BIGINT NOT NULL REFERENCES zonas(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT preventista_zonas_unique UNIQUE (perfil_id, zona_id)
);

-- RLS
ALTER TABLE preventista_zonas ENABLE ROW LEVEL SECURITY;
CREATE POLICY "prev_zonas_select_authenticated" ON preventista_zonas
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "prev_zonas_insert_authenticated" ON preventista_zonas
  FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "prev_zonas_update_authenticated" ON preventista_zonas
  FOR UPDATE TO authenticated USING (true);
CREATE POLICY "prev_zonas_delete_authenticated" ON preventista_zonas
  FOR DELETE TO authenticated USING (true);

-- 3. Agregar zona_id a clientes (coexiste con campo zona texto viejo)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'clientes' AND column_name = 'zona_id'
  ) THEN
    ALTER TABLE clientes ADD COLUMN zona_id BIGINT REFERENCES zonas(id);
  END IF;
END $$;

-- 4. Agregar zona_id a proveedores
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'proveedores' AND column_name = 'zona_id'
  ) THEN
    ALTER TABLE proveedores ADD COLUMN zona_id BIGINT REFERENCES zonas(id);
  END IF;
END $$;

-- 5. Insertar zonas predefinidas
INSERT INTO zonas (nombre) VALUES
  ('Centro'),
  ('Norte'),
  ('Sur'),
  ('Este'),
  ('Oeste'),
  ('Yerba Buena'),
  ('San Miguel de Tucumán'),
  ('Banda del Río Salí'),
  ('Las Talitas'),
  ('Alderetes')
ON CONFLICT (nombre) DO NOTHING;

-- 6. Migrar zonas existentes de clientes a la tabla zonas
INSERT INTO zonas (nombre)
SELECT DISTINCT zona FROM clientes
WHERE zona IS NOT NULL AND zona != '' AND zona NOT IN (SELECT nombre FROM zonas)
ON CONFLICT (nombre) DO NOTHING;

-- 7. Actualizar zona_id en clientes existentes
UPDATE clientes c
SET zona_id = z.id
FROM zonas z
WHERE c.zona = z.nombre AND c.zona_id IS NULL;

-- 8. Migrar zona de preventistas (perfiles.zona) a preventista_zonas
INSERT INTO preventista_zonas (perfil_id, zona_id)
SELECT p.id, z.id
FROM perfiles p
JOIN zonas z ON p.zona = z.nombre
WHERE p.zona IS NOT NULL AND p.zona != ''
ON CONFLICT (perfil_id, zona_id) DO NOTHING;

-- Indices
CREATE INDEX IF NOT EXISTS idx_preventista_zonas_perfil ON preventista_zonas(perfil_id);
CREATE INDEX IF NOT EXISTS idx_preventista_zonas_zona ON preventista_zonas(zona_id);
CREATE INDEX IF NOT EXISTS idx_clientes_zona_id ON clientes(zona_id);
CREATE INDEX IF NOT EXISTS idx_proveedores_zona_id ON proveedores(zona_id);

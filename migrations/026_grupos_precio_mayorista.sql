-- Migración 026: Sistema de Precios Mayoristas por Volumen
--
-- Permite agrupar productos y definir escalas de precio por volumen.
-- Ejemplo: "Papas Fritas" agrupa 3 sabores, a partir de 18 unidades
-- (sumando todos los sabores) se aplica precio mayorista.
--
-- Tablas:
--   1. grupos_precio - Definición de grupos
--   2. grupo_precio_productos - Productos en cada grupo
--   3. grupo_precio_escalas - Umbrales de precio por cantidad

-- =============================================================================
-- 1. Tabla principal de grupos de precio
-- =============================================================================

CREATE TABLE IF NOT EXISTS grupos_precio (
  id BIGSERIAL PRIMARY KEY,
  nombre VARCHAR(200) NOT NULL,
  descripcion TEXT,
  activo BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_grupos_precio_activo ON grupos_precio(activo);

-- =============================================================================
-- 2. Productos pertenecientes a cada grupo
-- =============================================================================

CREATE TABLE IF NOT EXISTS grupo_precio_productos (
  id BIGSERIAL PRIMARY KEY,
  grupo_precio_id BIGINT NOT NULL REFERENCES grupos_precio(id) ON DELETE CASCADE,
  producto_id BIGINT NOT NULL REFERENCES productos(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(grupo_precio_id, producto_id)
);

CREATE INDEX IF NOT EXISTS idx_gpp_grupo ON grupo_precio_productos(grupo_precio_id);
CREATE INDEX IF NOT EXISTS idx_gpp_producto ON grupo_precio_productos(producto_id);

-- =============================================================================
-- 3. Escalas de precio (umbrales) por grupo
-- =============================================================================

CREATE TABLE IF NOT EXISTS grupo_precio_escalas (
  id BIGSERIAL PRIMARY KEY,
  grupo_precio_id BIGINT NOT NULL REFERENCES grupos_precio(id) ON DELETE CASCADE,
  cantidad_minima INTEGER NOT NULL CHECK (cantidad_minima > 0),
  precio_unitario DECIMAL(12, 2) NOT NULL CHECK (precio_unitario > 0),
  etiqueta VARCHAR(100),
  activo BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(grupo_precio_id, cantidad_minima)
);

CREATE INDEX IF NOT EXISTS idx_gpe_grupo ON grupo_precio_escalas(grupo_precio_id);

-- =============================================================================
-- RLS: Lectura para todos los autenticados, escritura solo admin
-- =============================================================================

ALTER TABLE grupos_precio ENABLE ROW LEVEL SECURITY;
ALTER TABLE grupo_precio_productos ENABLE ROW LEVEL SECURITY;
ALTER TABLE grupo_precio_escalas ENABLE ROW LEVEL SECURITY;

-- grupos_precio
DROP POLICY IF EXISTS "Admin full access grupos_precio" ON grupos_precio;
CREATE POLICY "Admin full access grupos_precio" ON grupos_precio
  FOR ALL USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
  );

DROP POLICY IF EXISTS "Users can view grupos_precio" ON grupos_precio;
CREATE POLICY "Users can view grupos_precio" ON grupos_precio
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
  );

-- grupo_precio_productos
DROP POLICY IF EXISTS "Admin full access grupo_precio_productos" ON grupo_precio_productos;
CREATE POLICY "Admin full access grupo_precio_productos" ON grupo_precio_productos
  FOR ALL USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
  );

DROP POLICY IF EXISTS "Users can view grupo_precio_productos" ON grupo_precio_productos;
CREATE POLICY "Users can view grupo_precio_productos" ON grupo_precio_productos
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
  );

-- grupo_precio_escalas
DROP POLICY IF EXISTS "Admin full access grupo_precio_escalas" ON grupo_precio_escalas;
CREATE POLICY "Admin full access grupo_precio_escalas" ON grupo_precio_escalas
  FOR ALL USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
  );

DROP POLICY IF EXISTS "Users can view grupo_precio_escalas" ON grupo_precio_escalas;
CREATE POLICY "Users can view grupo_precio_escalas" ON grupo_precio_escalas
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
  );

-- =============================================================================
-- Trigger para updated_at en grupos_precio
-- =============================================================================

CREATE OR REPLACE FUNCTION update_grupos_precio_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_update_grupos_precio_timestamp ON grupos_precio;
CREATE TRIGGER trigger_update_grupos_precio_timestamp
  BEFORE UPDATE ON grupos_precio
  FOR EACH ROW
  EXECUTE FUNCTION update_grupos_precio_updated_at();

-- =============================================================================
-- Comentarios
-- =============================================================================

COMMENT ON TABLE grupos_precio IS 'Grupos de productos para precios mayoristas por volumen';
COMMENT ON TABLE grupo_precio_productos IS 'Productos pertenecientes a cada grupo de precio';
COMMENT ON TABLE grupo_precio_escalas IS 'Escalas de precio por volumen (umbrales) para cada grupo';
COMMENT ON COLUMN grupo_precio_escalas.cantidad_minima IS 'Cantidad mínima total del grupo para aplicar este precio';
COMMENT ON COLUMN grupo_precio_escalas.precio_unitario IS 'Precio unitario que aplica a TODOS los productos del grupo al alcanzar el umbral';
COMMENT ON COLUMN grupo_precio_escalas.etiqueta IS 'Etiqueta descriptiva, ej: Mayorista, Super Mayorista';

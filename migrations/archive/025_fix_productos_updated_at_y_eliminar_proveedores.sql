-- Migración 025: Fix productos.updated_at y agregar eliminación real de proveedores
--
-- 1. Agrega columna updated_at a productos (referenciada por RPC pero no existía)
-- 2. Crea tabla proveedores_eliminados para auditoría de borrados
-- 3. Crea función eliminar_proveedor que guarda registro y borra

-- =============================================================================
-- 1. Agregar updated_at a productos si no existe
-- =============================================================================

ALTER TABLE productos
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- Trigger para auto-actualizar updated_at en productos
CREATE OR REPLACE FUNCTION update_productos_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_update_productos_timestamp ON productos;
CREATE TRIGGER trigger_update_productos_timestamp
  BEFORE UPDATE ON productos
  FOR EACH ROW
  EXECUTE FUNCTION update_productos_updated_at();

-- =============================================================================
-- 2. Tabla de auditoría para proveedores eliminados
-- =============================================================================

CREATE TABLE IF NOT EXISTS proveedores_eliminados (
  id BIGSERIAL PRIMARY KEY,
  proveedor_id BIGINT NOT NULL,
  nombre VARCHAR(200) NOT NULL,
  cuit VARCHAR(20),
  direccion TEXT,
  telefono VARCHAR(50),
  email VARCHAR(100),
  contacto VARCHAR(100),
  notas TEXT,
  activo BOOLEAN,
  fecha_creacion TIMESTAMPTZ,
  eliminado_at TIMESTAMPTZ DEFAULT NOW(),
  eliminado_por UUID REFERENCES perfiles(id) ON DELETE SET NULL
);

-- RLS para proveedores_eliminados (solo admin puede ver/modificar)
ALTER TABLE proveedores_eliminados ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin full access proveedores_eliminados" ON proveedores_eliminados;
CREATE POLICY "Admin full access proveedores_eliminados" ON proveedores_eliminados
  FOR ALL USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
  );

-- =============================================================================
-- 3. Función para eliminar proveedor con registro de auditoría
-- =============================================================================

CREATE OR REPLACE FUNCTION eliminar_proveedor(
  p_proveedor_id BIGINT
)
RETURNS JSONB AS $$
DECLARE
  v_proveedor RECORD;
BEGIN
  -- Buscar el proveedor
  SELECT * INTO v_proveedor
  FROM proveedores
  WHERE id = p_proveedor_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Proveedor no encontrado');
  END IF;

  -- Guardar registro en tabla de auditoría
  INSERT INTO proveedores_eliminados (
    proveedor_id, nombre, cuit, direccion, telefono, email,
    contacto, notas, activo, fecha_creacion, eliminado_por
  ) VALUES (
    v_proveedor.id,
    v_proveedor.nombre,
    v_proveedor.cuit,
    v_proveedor.direccion,
    v_proveedor.telefono,
    v_proveedor.email,
    v_proveedor.contacto,
    v_proveedor.notas,
    v_proveedor.activo,
    v_proveedor.created_at,
    auth.uid()
  );

  -- Eliminar el proveedor (compras mantienen proveedor_nombre por ON DELETE SET NULL)
  DELETE FROM proveedores WHERE id = p_proveedor_id;

  RETURN jsonb_build_object(
    'success', true,
    'nombre', v_proveedor.nombre
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON TABLE proveedores_eliminados IS 'Registro de auditoría de proveedores eliminados';
COMMENT ON FUNCTION eliminar_proveedor IS 'Elimina un proveedor guardando registro de auditoría';

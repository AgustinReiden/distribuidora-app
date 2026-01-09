-- Migración para agregar módulo de compras
-- Permite registrar compras a proveedores y actualizar stock automáticamente

-- Crear tabla de proveedores (opcional, para futuras mejoras)
CREATE TABLE IF NOT EXISTS proveedores (
  id BIGSERIAL PRIMARY KEY,
  nombre VARCHAR(200) NOT NULL,
  cuit VARCHAR(20),
  direccion TEXT,
  telefono VARCHAR(50),
  email VARCHAR(100),
  contacto VARCHAR(100),
  notas TEXT,
  activo BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Crear tabla principal de compras
CREATE TABLE IF NOT EXISTS compras (
  id BIGSERIAL PRIMARY KEY,
  proveedor_id BIGINT REFERENCES proveedores(id) ON DELETE SET NULL,
  proveedor_nombre VARCHAR(200), -- Para cuando no se usa proveedor registrado
  numero_factura VARCHAR(100),
  fecha_compra DATE NOT NULL DEFAULT CURRENT_DATE,
  fecha_recepcion DATE,
  subtotal DECIMAL(12, 2) NOT NULL DEFAULT 0,
  iva DECIMAL(12, 2) NOT NULL DEFAULT 0,
  otros_impuestos DECIMAL(12, 2) NOT NULL DEFAULT 0,
  total DECIMAL(12, 2) NOT NULL DEFAULT 0,
  forma_pago VARCHAR(50) DEFAULT 'efectivo' CHECK (forma_pago IN ('efectivo', 'transferencia', 'cheque', 'cuenta_corriente', 'tarjeta')),
  estado VARCHAR(50) DEFAULT 'pendiente' CHECK (estado IN ('pendiente', 'recibida', 'parcial', 'cancelada')),
  notas TEXT,
  usuario_id UUID REFERENCES perfiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Crear tabla de items de compra
CREATE TABLE IF NOT EXISTS compra_items (
  id BIGSERIAL PRIMARY KEY,
  compra_id BIGINT NOT NULL REFERENCES compras(id) ON DELETE CASCADE,
  producto_id BIGINT NOT NULL REFERENCES productos(id) ON DELETE CASCADE,
  cantidad INTEGER NOT NULL CHECK (cantidad > 0),
  costo_unitario DECIMAL(12, 2) NOT NULL DEFAULT 0,
  subtotal DECIMAL(12, 2) NOT NULL DEFAULT 0,
  stock_anterior INTEGER NOT NULL DEFAULT 0,
  stock_nuevo INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Índices para búsquedas frecuentes
CREATE INDEX IF NOT EXISTS idx_compras_fecha ON compras(fecha_compra DESC);
CREATE INDEX IF NOT EXISTS idx_compras_proveedor ON compras(proveedor_id);
CREATE INDEX IF NOT EXISTS idx_compras_estado ON compras(estado);
CREATE INDEX IF NOT EXISTS idx_compras_created ON compras(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_compra_items_compra ON compra_items(compra_id);
CREATE INDEX IF NOT EXISTS idx_compra_items_producto ON compra_items(producto_id);
CREATE INDEX IF NOT EXISTS idx_proveedores_nombre ON proveedores(nombre);

-- Habilitar RLS
ALTER TABLE compras ENABLE ROW LEVEL SECURITY;
ALTER TABLE compra_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE proveedores ENABLE ROW LEVEL SECURITY;

-- Políticas de seguridad para compras
CREATE POLICY "Admin full access compras" ON compras
  FOR ALL USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
  );

CREATE POLICY "Users can view compras" ON compras
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
  );

-- Políticas de seguridad para compra_items
CREATE POLICY "Admin full access compra_items" ON compra_items
  FOR ALL USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
  );

CREATE POLICY "Users can view compra_items" ON compra_items
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
  );

-- Políticas de seguridad para proveedores
CREATE POLICY "Admin full access proveedores" ON proveedores
  FOR ALL USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
  );

CREATE POLICY "Users can view proveedores" ON proveedores
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
  );

-- Función para registrar compra completa con actualización de stock
CREATE OR REPLACE FUNCTION registrar_compra_completa(
  p_proveedor_id BIGINT DEFAULT NULL,
  p_proveedor_nombre VARCHAR DEFAULT NULL,
  p_numero_factura VARCHAR DEFAULT NULL,
  p_fecha_compra DATE DEFAULT CURRENT_DATE,
  p_subtotal DECIMAL DEFAULT 0,
  p_iva DECIMAL DEFAULT 0,
  p_otros_impuestos DECIMAL DEFAULT 0,
  p_total DECIMAL DEFAULT 0,
  p_forma_pago VARCHAR DEFAULT 'efectivo',
  p_notas TEXT DEFAULT NULL,
  p_usuario_id UUID DEFAULT NULL,
  p_items JSONB DEFAULT '[]'
)
RETURNS JSONB AS $$
DECLARE
  v_compra_id BIGINT;
  v_item JSONB;
  v_producto RECORD;
  v_stock_anterior INTEGER;
  v_stock_nuevo INTEGER;
  v_items_procesados JSONB := '[]'::JSONB;
BEGIN
  -- Crear la compra
  INSERT INTO compras (
    proveedor_id, proveedor_nombre, numero_factura, fecha_compra,
    subtotal, iva, otros_impuestos, total, forma_pago, notas, usuario_id, estado
  ) VALUES (
    p_proveedor_id, p_proveedor_nombre, p_numero_factura, p_fecha_compra,
    p_subtotal, p_iva, p_otros_impuestos, p_total, p_forma_pago, p_notas, p_usuario_id, 'recibida'
  ) RETURNING id INTO v_compra_id;

  -- Procesar cada item
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    -- Obtener stock actual del producto
    SELECT id, stock INTO v_producto
    FROM productos
    WHERE id = (v_item->>'producto_id')::BIGINT;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Producto no encontrado: %', v_item->>'producto_id';
    END IF;

    v_stock_anterior := COALESCE(v_producto.stock, 0);
    v_stock_nuevo := v_stock_anterior + (v_item->>'cantidad')::INTEGER;

    -- Insertar item de compra
    INSERT INTO compra_items (
      compra_id, producto_id, cantidad, costo_unitario, subtotal,
      stock_anterior, stock_nuevo
    ) VALUES (
      v_compra_id,
      (v_item->>'producto_id')::BIGINT,
      (v_item->>'cantidad')::INTEGER,
      COALESCE((v_item->>'costo_unitario')::DECIMAL, 0),
      COALESCE((v_item->>'subtotal')::DECIMAL, 0),
      v_stock_anterior,
      v_stock_nuevo
    );

    -- Actualizar stock del producto
    UPDATE productos
    SET stock = v_stock_nuevo,
        updated_at = NOW()
    WHERE id = (v_item->>'producto_id')::BIGINT;

    -- Agregar a items procesados
    v_items_procesados := v_items_procesados || jsonb_build_object(
      'producto_id', (v_item->>'producto_id')::BIGINT,
      'cantidad', (v_item->>'cantidad')::INTEGER,
      'stock_anterior', v_stock_anterior,
      'stock_nuevo', v_stock_nuevo
    );
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'compra_id', v_compra_id,
    'items_procesados', v_items_procesados
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Función para obtener resumen de compras por período
CREATE OR REPLACE FUNCTION obtener_resumen_compras(
  p_fecha_desde DATE DEFAULT NULL,
  p_fecha_hasta DATE DEFAULT NULL
)
RETURNS TABLE (
  total_compras BIGINT,
  monto_total DECIMAL,
  promedio_compra DECIMAL,
  productos_comprados BIGINT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    COUNT(DISTINCT c.id)::BIGINT as total_compras,
    COALESCE(SUM(c.total), 0)::DECIMAL as monto_total,
    COALESCE(AVG(c.total), 0)::DECIMAL as promedio_compra,
    COALESCE(SUM(ci.cantidad), 0)::BIGINT as productos_comprados
  FROM compras c
  LEFT JOIN compra_items ci ON c.id = ci.compra_id
  WHERE c.estado != 'cancelada'
    AND (p_fecha_desde IS NULL OR c.fecha_compra >= p_fecha_desde)
    AND (p_fecha_hasta IS NULL OR c.fecha_compra <= p_fecha_hasta);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger para actualizar updated_at en compras
CREATE OR REPLACE FUNCTION update_compras_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_compras_timestamp
  BEFORE UPDATE ON compras
  FOR EACH ROW
  EXECUTE FUNCTION update_compras_updated_at();

CREATE TRIGGER trigger_update_proveedores_timestamp
  BEFORE UPDATE ON proveedores
  FOR EACH ROW
  EXECUTE FUNCTION update_compras_updated_at();

-- Comentarios para documentación
COMMENT ON TABLE compras IS 'Registro de compras a proveedores con actualización automática de stock';
COMMENT ON TABLE compra_items IS 'Items individuales de cada compra';
COMMENT ON TABLE proveedores IS 'Catálogo de proveedores';
COMMENT ON COLUMN compras.estado IS 'Estado de la compra: pendiente, recibida, parcial, cancelada';
COMMENT ON COLUMN compra_items.stock_anterior IS 'Stock del producto antes de la compra';
COMMENT ON COLUMN compra_items.stock_nuevo IS 'Stock del producto después de la compra';

-- Migración para agregar tabla de mermas/bajas de stock
-- Esta tabla permite registrar pérdidas de stock con trazabilidad completa

-- Crear tabla de mermas de stock
CREATE TABLE IF NOT EXISTS mermas_stock (
  id BIGSERIAL PRIMARY KEY,
  producto_id BIGINT NOT NULL REFERENCES productos(id) ON DELETE CASCADE,
  cantidad INTEGER NOT NULL CHECK (cantidad > 0),
  motivo VARCHAR(50) NOT NULL CHECK (motivo IN ('rotura', 'vencimiento', 'robo', 'decomiso', 'devolucion', 'error_inventario', 'muestra', 'otro')),
  observaciones TEXT,
  stock_anterior INTEGER NOT NULL,
  stock_nuevo INTEGER NOT NULL,
  usuario_id UUID REFERENCES perfiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Índices para búsquedas frecuentes
CREATE INDEX IF NOT EXISTS idx_mermas_producto ON mermas_stock(producto_id);
CREATE INDEX IF NOT EXISTS idx_mermas_fecha ON mermas_stock(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mermas_motivo ON mermas_stock(motivo);

-- Habilitar RLS
ALTER TABLE mermas_stock ENABLE ROW LEVEL SECURITY;

-- Políticas de seguridad
-- Admin puede ver y crear todas las mermas
CREATE POLICY "Admin full access mermas" ON mermas_stock
  FOR ALL USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
  );

-- Otros usuarios pueden ver mermas (para reportes) pero no pueden crear/modificar directamente
CREATE POLICY "Users can view mermas" ON mermas_stock
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
  );

-- Función para obtener resumen de mermas por período
CREATE OR REPLACE FUNCTION obtener_resumen_mermas(
  p_fecha_desde DATE DEFAULT NULL,
  p_fecha_hasta DATE DEFAULT NULL
)
RETURNS TABLE (
  motivo VARCHAR,
  total_cantidad BIGINT,
  total_registros BIGINT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    m.motivo,
    SUM(m.cantidad)::BIGINT as total_cantidad,
    COUNT(*)::BIGINT as total_registros
  FROM mermas_stock m
  WHERE (p_fecha_desde IS NULL OR m.created_at >= p_fecha_desde)
    AND (p_fecha_hasta IS NULL OR m.created_at <= p_fecha_hasta + INTERVAL '1 day')
  GROUP BY m.motivo
  ORDER BY total_cantidad DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Comentarios para documentación
COMMENT ON TABLE mermas_stock IS 'Registro de bajas de stock por pérdidas, roturas, vencimientos, etc.';
COMMENT ON COLUMN mermas_stock.motivo IS 'Motivo de la baja: rotura, vencimiento, robo, decomiso, devolucion, error_inventario, muestra, otro';
COMMENT ON COLUMN mermas_stock.stock_anterior IS 'Stock del producto antes de la baja';
COMMENT ON COLUMN mermas_stock.stock_nuevo IS 'Stock del producto después de la baja';

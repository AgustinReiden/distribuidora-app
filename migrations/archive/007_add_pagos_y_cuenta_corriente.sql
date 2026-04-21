-- Migration: Add payments table and credit limit for account management
-- Run this in Supabase SQL Editor

-- Add credit limit and balance tracking to clients
ALTER TABLE clientes ADD COLUMN IF NOT EXISTS limite_credito DECIMAL(12,2) DEFAULT 0;
ALTER TABLE clientes ADD COLUMN IF NOT EXISTS saldo_cuenta DECIMAL(12,2) DEFAULT 0;
ALTER TABLE clientes ADD COLUMN IF NOT EXISTS dias_credito INTEGER DEFAULT 30;

-- Create payments table
CREATE TABLE IF NOT EXISTS pagos (
  id SERIAL PRIMARY KEY,
  cliente_id INTEGER NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
  pedido_id INTEGER REFERENCES pedidos(id) ON DELETE SET NULL,
  monto DECIMAL(12,2) NOT NULL,
  forma_pago VARCHAR(50) NOT NULL DEFAULT 'efectivo',
  referencia VARCHAR(255),
  notas TEXT,
  usuario_id UUID REFERENCES perfiles(id),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create index for faster queries
CREATE INDEX IF NOT EXISTS idx_pagos_cliente_id ON pagos(cliente_id);
CREATE INDEX IF NOT EXISTS idx_pagos_pedido_id ON pagos(pedido_id);
CREATE INDEX IF NOT EXISTS idx_pagos_created_at ON pagos(created_at DESC);

-- Function to update client balance when payment is made
CREATE OR REPLACE FUNCTION actualizar_saldo_cliente()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE clientes SET saldo_cuenta = saldo_cuenta - NEW.monto WHERE id = NEW.cliente_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE clientes SET saldo_cuenta = saldo_cuenta + OLD.monto WHERE id = OLD.cliente_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to auto-update balance
DROP TRIGGER IF EXISTS trigger_actualizar_saldo_pago ON pagos;
CREATE TRIGGER trigger_actualizar_saldo_pago
AFTER INSERT OR DELETE ON pagos
FOR EACH ROW EXECUTE FUNCTION actualizar_saldo_cliente();

-- Function to update client balance when order is created
CREATE OR REPLACE FUNCTION actualizar_saldo_pedido()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE clientes SET saldo_cuenta = saldo_cuenta + NEW.total WHERE id = NEW.cliente_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE clientes SET saldo_cuenta = saldo_cuenta - OLD.total WHERE id = OLD.cliente_id;
  ELSIF TG_OP = 'UPDATE' AND OLD.total != NEW.total THEN
    UPDATE clientes SET saldo_cuenta = saldo_cuenta - OLD.total + NEW.total WHERE id = NEW.cliente_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger for orders affecting balance
DROP TRIGGER IF EXISTS trigger_actualizar_saldo_pedido ON pedidos;
CREATE TRIGGER trigger_actualizar_saldo_pedido
AFTER INSERT OR DELETE OR UPDATE OF total ON pedidos
FOR EACH ROW EXECUTE FUNCTION actualizar_saldo_pedido();

-- RPC function to get client account summary
CREATE OR REPLACE FUNCTION obtener_resumen_cuenta_cliente(p_cliente_id INTEGER)
RETURNS JSON AS $$
DECLARE
  resultado JSON;
BEGIN
  SELECT json_build_object(
    'saldo_actual', COALESCE(c.saldo_cuenta, 0),
    'limite_credito', COALESCE(c.limite_credito, 0),
    'credito_disponible', COALESCE(c.limite_credito, 0) - COALESCE(c.saldo_cuenta, 0),
    'total_pedidos', (SELECT COUNT(*) FROM pedidos WHERE cliente_id = p_cliente_id),
    'total_compras', (SELECT COALESCE(SUM(total), 0) FROM pedidos WHERE cliente_id = p_cliente_id),
    'total_pagos', (SELECT COALESCE(SUM(monto), 0) FROM pagos WHERE cliente_id = p_cliente_id),
    'pedidos_pendientes_pago', (SELECT COUNT(*) FROM pedidos WHERE cliente_id = p_cliente_id AND estado_pago != 'pagado'),
    'ultimo_pedido', (SELECT MAX(created_at) FROM pedidos WHERE cliente_id = p_cliente_id),
    'ultimo_pago', (SELECT MAX(created_at) FROM pagos WHERE cliente_id = p_cliente_id)
  ) INTO resultado
  FROM clientes c
  WHERE c.id = p_cliente_id;

  RETURN resultado;
END;
$$ LANGUAGE plpgsql;

-- Enable RLS on pagos table
ALTER TABLE pagos ENABLE ROW LEVEL SECURITY;

-- RLS Policies for pagos (allow all authenticated users to CRUD)
CREATE POLICY "Allow authenticated users to view payments" ON pagos FOR SELECT TO authenticated USING (true);
CREATE POLICY "Allow authenticated users to insert payments" ON pagos FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Allow authenticated users to update payments" ON pagos FOR UPDATE TO authenticated USING (true);
CREATE POLICY "Allow authenticated users to delete payments" ON pagos FOR DELETE TO authenticated USING (true);

-- Initialize existing client balances based on orders and payments
-- Run this after creating tables to sync existing data
DO $$
BEGIN
  UPDATE clientes c SET saldo_cuenta = (
    COALESCE((SELECT SUM(total) FROM pedidos WHERE cliente_id = c.id), 0) -
    COALESCE((SELECT SUM(monto) FROM pagos WHERE cliente_id = c.id), 0)
  );
END $$;

COMMENT ON TABLE pagos IS 'Registro de pagos realizados por clientes';
COMMENT ON COLUMN clientes.limite_credito IS 'Límite de crédito asignado al cliente';
COMMENT ON COLUMN clientes.saldo_cuenta IS 'Saldo actual de la cuenta corriente (positivo = debe, negativo = a favor)';
COMMENT ON COLUMN clientes.dias_credito IS 'Días de crédito otorgados al cliente';

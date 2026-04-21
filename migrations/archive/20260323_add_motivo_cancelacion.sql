-- Add motivo_cancelacion column to pedidos table
-- Stores the reason when an order is cancelled (estado = 'cancelado')
ALTER TABLE pedidos ADD COLUMN IF NOT EXISTS motivo_cancelacion TEXT;

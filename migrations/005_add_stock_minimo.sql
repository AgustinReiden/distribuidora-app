-- Agregar campo stock_minimo a la tabla productos
-- Este campo permite definir un umbral personalizado de alerta de stock bajo para cada producto

ALTER TABLE productos
ADD COLUMN IF NOT EXISTS stock_minimo INTEGER DEFAULT 10;

COMMENT ON COLUMN productos.stock_minimo IS 'Stock mínimo de seguridad. Cuando el stock actual está por debajo de este valor, se activa la alerta de stock bajo';

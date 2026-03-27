-- Migración 036: Cantidad mínima de pedido por producto en grupos mayoristas
-- Permite configurar un MOQ (minimum order quantity) por producto dentro de cada grupo.
-- NULL = sin mínimo (backward compatible).

ALTER TABLE grupo_precio_productos
  ADD COLUMN cantidad_minima_pedido INTEGER DEFAULT NULL;

ALTER TABLE grupo_precio_productos
  ADD CONSTRAINT chk_cantidad_minima_pedido_positiva
  CHECK (cantidad_minima_pedido IS NULL OR cantidad_minima_pedido > 0);

COMMENT ON COLUMN grupo_precio_productos.cantidad_minima_pedido
  IS 'Cantidad mínima de pedido por producto dentro de este grupo. NULL = sin mínimo.';

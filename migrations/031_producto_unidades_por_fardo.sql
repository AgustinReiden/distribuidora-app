-- Migration 031: Agregar campo de unidades por fardo en productos
-- Permite imprimir aclaración "(1 FARDO)" / "(MEDIO FARDO)" en recibos cuando
-- la cantidad vendida coincide con un múltiplo (entero o medio) del fardo.
--
-- Ejemplo: SAL FINA con unidades_de_venta_por_fardo=2 →
--   1 unidad vendida → "(MEDIO FARDO)"
--   2 unidades       → "(1 FARDO)"
--   3 unidades       → "(1 FARDO Y MEDIO)"
--   4 unidades       → "(2 FARDOS)"

ALTER TABLE productos
  ADD COLUMN IF NOT EXISTS unidades_de_venta_por_fardo numeric(10,2),
  ADD COLUMN IF NOT EXISTS etiqueta_bulto text DEFAULT 'FARDO';

COMMENT ON COLUMN productos.unidades_de_venta_por_fardo IS
  'Cantidad de unidades de venta que componen 1 fardo. Si NULL, no se imprime aclaración.';
COMMENT ON COLUMN productos.etiqueta_bulto IS
  'Etiqueta del bulto (FARDO, CAJA, PACK, BULTO). Default FARDO.';

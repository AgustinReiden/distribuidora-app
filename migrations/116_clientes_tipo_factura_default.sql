-- ============================================================================
-- 116 · clientes.tipo_factura_default: FC/ZZ por defecto al crear pedidos
-- ============================================================================
-- La app solo ETIQUETA los pedidos como FC (con factura, emitida por fuera)
-- o ZZ (sin factura). El default por cliente evita que el operador tenga que
-- acordarse a quién se le factura. El guard-trigger allow-list de clientes
-- (trg_clientes_proteger_columnas) ya bloquea esta columna para preventistas
-- automáticamente (solo permite razon_social/direccion/etc.).
-- ============================================================================

ALTER TABLE public.clientes
  ADD COLUMN IF NOT EXISTS tipo_factura_default varchar(2) NOT NULL DEFAULT 'ZZ';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'clientes_tipo_factura_default_check'
  ) THEN
    ALTER TABLE public.clientes
      ADD CONSTRAINT clientes_tipo_factura_default_check
      CHECK (tipo_factura_default IN ('ZZ','FC'));
  END IF;
END $$;

COMMENT ON COLUMN public.clientes.tipo_factura_default IS
  'Tipo de comprobante por defecto para los pedidos de este cliente: FC = se le factura (emisión externa), ZZ = sin factura. El modal de pedido lo preselecciona; se puede pisar por pedido.';

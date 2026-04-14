-- Migration 045: Agregar tipo_factura (ZZ/FC) a pedidos y compras
--
-- ZZ = Sin factura (sin IVA discriminado) - default para ventas
-- FC = Con factura (IVA discriminado) - default para compras
--
-- El precio final al consumidor es siempre el mismo.
-- ZZ: ingreso neto = precio final completo
-- FC: ingreso neto = precio neto (IVA se remite a AFIP)

-- =============================================
-- 1. PEDIDOS - agregar tipo_factura y desglose
-- =============================================

ALTER TABLE pedidos
  ADD COLUMN IF NOT EXISTS tipo_factura VARCHAR(2) DEFAULT 'ZZ'
    CHECK (tipo_factura IN ('ZZ', 'FC')),
  ADD COLUMN IF NOT EXISTS total_neto DECIMAL(12,2),
  ADD COLUMN IF NOT EXISTS total_iva DECIMAL(12,2) DEFAULT 0;

-- Backfill: pedidos existentes son ZZ, total_neto = total
UPDATE pedidos SET total_neto = total WHERE total_neto IS NULL;

-- =============================================
-- 2. PEDIDO_ITEMS - desglose por item
-- =============================================

ALTER TABLE pedido_items
  ADD COLUMN IF NOT EXISTS neto_unitario DECIMAL(12,2),
  ADD COLUMN IF NOT EXISTS iva_unitario DECIMAL(12,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS impuestos_internos_unitario DECIMAL(12,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS porcentaje_iva DECIMAL(5,2) DEFAULT 0;

-- =============================================
-- 3. COMPRAS - agregar tipo_factura
-- =============================================

ALTER TABLE compras
  ADD COLUMN IF NOT EXISTS tipo_factura VARCHAR(2) DEFAULT 'FC'
    CHECK (tipo_factura IN ('ZZ', 'FC'));

-- =============================================
-- 4. INDICES
-- =============================================

CREATE INDEX IF NOT EXISTS idx_pedidos_tipo_factura ON pedidos(tipo_factura);
CREATE INDEX IF NOT EXISTS idx_compras_tipo_factura ON compras(tipo_factura);

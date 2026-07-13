-- ============================================================================
-- 113 · Compras: columnas de desglose fiscal completo (percepciones, no
--       gravado, imp. internos propio) + snapshots fiscales por línea
-- ============================================================================
-- Contexto (Fase B del rediseño fiscal):
--   · El monto de impuestos internos calculado por el modal se guardaba en
--     compras.otros_impuestos (concepto equivocado). Ahora tiene columna
--     propia y otros_impuestos vuelve a ser un catch-all. Backfill: en prod
--     hay 4 filas con otros_impuestos > 0, todas eran II del modal.
--   · Percepción IVA (ej: RG 5329 3% sobre gravado) y percepción IIBB son
--     CRÉDITOS fiscales: se registran para seguimiento (posición fiscal),
--     NO integran el costo del producto.
--   · no_gravado: conceptos de factura fuera del IVA (ej: pallets/separadores
--     valorizados). No integran costo unitario; hacen cuadrar el total.
--   · compra_items snapshotea la tasa de IVA/II aplicada y el costo neto y
--     real por unidad → historial de costos confiable por línea.
-- Sin CHECK duro de consistencia de total: las 43 compras ZZ legacy y los
-- redondeos de factura lo violarían; el control es blando (warning del RPC +
-- panel "Control contra factura" en el modal).
-- ============================================================================

ALTER TABLE public.compras
  ADD COLUMN IF NOT EXISTS impuestos_internos numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS percepcion_iva     numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS percepcion_iibb    numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS no_gravado         numeric(12,2) NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.compras.impuestos_internos IS
  'Monto total de impuestos internos de la factura (antes se guardaba en otros_impuestos). Integra el costo real de los productos.';
COMMENT ON COLUMN public.compras.percepcion_iva IS
  'Percepción de IVA de la factura (ej: RG 5329 3% sobre gravado). Crédito fiscal, NO costo.';
COMMENT ON COLUMN public.compras.percepcion_iibb IS
  'Percepción de IIBB de la factura. Crédito fiscal, NO costo.';
COMMENT ON COLUMN public.compras.no_gravado IS
  'Conceptos no gravados de la factura (ej: pallets/separadores valorizados). No integran costo unitario; cuadran el total.';
COMMENT ON COLUMN public.compras.otros_impuestos IS
  'Catch-all para otros conceptos impositivos. Hasta mig 113 guardaba (mal) el monto de imp. internos.';

-- Backfill: el II del modal vivía en otros_impuestos (4 filas en prod)
UPDATE public.compras
   SET impuestos_internos = otros_impuestos,
       otros_impuestos    = 0
 WHERE otros_impuestos > 0;

ALTER TABLE public.compra_items
  ADD COLUMN IF NOT EXISTS porcentaje_iva      numeric(5,2),
  ADD COLUMN IF NOT EXISTS impuestos_internos  numeric(8,4),
  ADD COLUMN IF NOT EXISTS costo_neto_unitario numeric(12,4),
  ADD COLUMN IF NOT EXISTS costo_real_unitario numeric(12,4);

COMMENT ON COLUMN public.compra_items.porcentaje_iva IS
  'Tasa de IVA aplicada en esta línea (snapshot al registrar; NULL = línea previa a mig 113).';
COMMENT ON COLUMN public.compra_items.impuestos_internos IS
  'Tasa EFECTIVA de imp. internos aplicada en esta línea, en % sobre el neto (snapshot).';
COMMENT ON COLUMN public.compra_items.costo_neto_unitario IS
  'Costo unitario post-bonificación (snapshot). costo_unitario es el bruto pre-bonif.';
COMMENT ON COLUMN public.compra_items.costo_real_unitario IS
  'Costo real por unidad (canónico mig 111): FC = neto×(1+II/100); ZZ = pagado. Historial de costos confiable.';

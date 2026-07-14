-- ============================================================================
-- 119 · mermas_stock.costo_unitario: snapshot de costo al registrar la merma
-- ============================================================================
-- Riesgo documentado (docs/plan-auditoria-integridad.md ítem 8): las mermas se
-- valuaban SIEMPRE a costo vivo → el KPI de un mes cerrado cambiaba si después
-- se actualizaba el costo del producto. El trigger BEFORE INSERT congela el
-- costo_real canónico (mig 111) en el alta, cubriendo TODOS los caminos de
-- inserción (useMermas, auto-ajuste de promos en crear/editar pedido, control
-- de stock) sin tocar cada uno. Filas históricas quedan NULL (fallback a costo
-- vivo en lectura, mig 120).
-- ============================================================================

ALTER TABLE public.mermas_stock
  ADD COLUMN IF NOT EXISTS costo_unitario numeric(12,4);

COMMENT ON COLUMN public.mermas_stock.costo_unitario IS
  'Costo real por unidad congelado al registrar la merma (productos.costo_real, mig 111). NULL = fila previa a mig 119 → el reporte cae al costo vivo.';

CREATE OR REPLACE FUNCTION public.mermas_stock_snapshot_costo()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.costo_unitario IS NULL THEN
    SELECT COALESCE(costo_real, round(costo_sin_iva * (1 + COALESCE(impuestos_internos, 0) / 100), 4))
      INTO NEW.costo_unitario
      FROM productos
     WHERE id = NEW.producto_id AND sucursal_id = NEW.sucursal_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_mermas_snapshot_costo ON public.mermas_stock;
CREATE TRIGGER trg_mermas_snapshot_costo
  BEFORE INSERT ON public.mermas_stock
  FOR EACH ROW EXECUTE FUNCTION public.mermas_stock_snapshot_costo();

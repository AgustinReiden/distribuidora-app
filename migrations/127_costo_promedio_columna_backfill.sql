-- ============================================================================
-- 127 · productos.costo_promedio: costo promedio ponderado (CPP) por sucursal
-- ============================================================================
-- Problema: el modelo "último costo gana" revalúa TODO el stock existente al
-- costo de la última compra. Si compro 100u en ZZ a 121 (total = costo) y a la
-- semana compro en FC a 100 neto, las 80u viejas pasan a costearse a 100:
-- CMV subvaluado, margen inflado (y viceversa cuando el costo sube).
--
-- Solución: doble rol del costo.
--   · costo_real       → costo de REPOSICIÓN (última compra FC/ZZ). Base para
--                        pricing. Se sigue actualizando igual que hoy.
--   · costo_promedio   → costo promedio ponderado, base de VALUACIÓN y CMV.
--                        Al comprar: (stock_ant × cpp + cant × costo_real_nuevo)
--                                    / (stock_ant + cant)
--                        Se recalcula en registrar_compra_completa (mig 128).
--
-- Política forward-only: ediciones y anulaciones de compras NO retro-ajustan
-- el promedio (es dependiente del camino). El admin puede corregirlo a mano
-- desde la ficha del producto.
--
-- productos es por sucursal (sucursal_id en la fila) ⇒ el CPP es por sucursal.
-- ============================================================================

ALTER TABLE public.productos
  ADD COLUMN IF NOT EXISTS costo_promedio numeric(12,4);

COMMENT ON COLUMN public.productos.costo_promedio IS
  'Costo promedio ponderado (valuación de stock y CMV). Se recalcula en registrar_compra_completa; forward-only: ediciones/anulaciones de compras no lo retro-ajustan (corregible a mano por admin). costo_real sigue siendo el costo de reposición (última compra).';

-- Backfill: arranca igual al costo real vigente (misma cascada de fallback que
-- ya usa reporte_gerencial para filas sin costo_real).
UPDATE public.productos
   SET costo_promedio = COALESCE(
         costo_real,
         round(costo_sin_iva * (1 + COALESCE(impuestos_internos, 0) / 100), 4)
       )
 WHERE costo_promedio IS NULL;

/**
 * El stock mínimo de un producto y cuándo su stock está "bajo" (CAT-13, #1596).
 *
 * Las pantallas leían `stock_minimo || 10` (un 0 valía 10) y comparaban con `<`;
 * el Excel y el bot leían 0 como 0 y comparaban con `<=`: el mismo producto
 * figuraba bajo en un lado y bien en el otro. Decisión del dueño, una sola regla:
 *
 *  - sin dato (null / vacío) → se usa 10;
 *  - 0 → "sin alerta" para ese producto: nunca está bajo;
 *  - si no, está bajo cuando `stock <= mínimo`.
 *
 * El bot (SQL) tiene que seguir la misma regla: no es de este módulo.
 */
export const STOCK_MINIMO_POR_DEFECTO = 10

/** El mínimo que rige para el producto; 0 = sin alerta. */
export function stockMinimoEfectivo(stockMinimo: number | string | null | undefined): number {
  if (stockMinimo === null || stockMinimo === undefined || stockMinimo === '') return STOCK_MINIMO_POR_DEFECTO
  const n = Number(stockMinimo)
  return Number.isFinite(n) && n >= 0 ? n : STOCK_MINIMO_POR_DEFECTO
}

/** ¿Tiene alerta de stock bajo? Un mínimo de 0 la apaga. */
export function tieneAlertaDeStock(stockMinimo: number | string | null | undefined): boolean {
  return stockMinimoEfectivo(stockMinimo) > 0
}

/** ¿El stock está en el mínimo o por debajo? Sin alerta (mínimo 0), nunca. */
export function stockBajo(
  stock: number | string | null | undefined,
  stockMinimo: number | string | null | undefined,
): boolean {
  const minimo = stockMinimoEfectivo(stockMinimo)
  if (minimo === 0) return false
  return Number(stock ?? 0) <= minimo
}

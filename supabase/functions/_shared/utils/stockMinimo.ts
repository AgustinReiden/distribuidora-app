/**
 * El stock mínimo de un producto y cuándo su stock está "bajo", en el bot (CAT-13,
 * #1596). Espejo de `src/utils/stockMinimo.ts` y de `bot_metricas_admin_dia`
 * (SQL): las tres siguen la misma regla, decisión del dueño (D30):
 *
 *  - sin dato (null / vacío / negativo) → se usa 10;
 *  - 0 → "sin alerta" para ese producto: nunca está bajo;
 *  - si no, está bajo cuando `stock <= mínimo`.
 *
 * Las herramientas leían `stock_minimo ?? 0` con `<=`: un producto sin mínimo
 * cargado y sin stock figuraba "bajo mínimo" con mínimo 0, y uno con mínimo 0
 * también, mientras las pantallas no lo marcaban.
 */
export const STOCK_MINIMO_POR_DEFECTO = 10;

/** El mínimo que rige para el producto; 0 = sin alerta. */
export function stockMinimoEfectivo(stockMinimo: number | string | null | undefined): number {
  if (stockMinimo === null || stockMinimo === undefined || stockMinimo === "") {
    return STOCK_MINIMO_POR_DEFECTO;
  }
  const n = Number(stockMinimo);
  return Number.isFinite(n) && n >= 0 ? n : STOCK_MINIMO_POR_DEFECTO;
}

/** ¿El stock está en el mínimo o por debajo? Sin alerta (mínimo 0), nunca. */
export function stockBajo(
  stock: number | string | null | undefined,
  stockMinimo: number | string | null | undefined,
): boolean {
  const minimo = stockMinimoEfectivo(stockMinimo);
  if (minimo === 0) return false;
  return Number(stock ?? 0) <= minimo;
}

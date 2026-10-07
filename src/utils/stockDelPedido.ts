/**
 * Cuánto stock descuenta un pedido, por producto. Es el espejo en el front de
 * cómo `crear_pedido_completo` arma `v_cantidades_stock` (mig 132): la venta
 * suma; el regalo suma SÓLO si su promo tiene `regalo_mueve_stock` (un regalo
 * sin promo, o de una promo de fracción, no compite por el stock del producto —
 * su fardo lo valida el auto-ajuste del servidor).
 *
 * Es la única copia de la regla en el front para la validación offline: la usan
 * `validarStockAntesDeEncolar` (al encolar y, sin reservas, antes del replay) y
 * sus reservas de pedidos pendientes. Sin sumar por producto, un mismo producto
 * comprado y regalado pasaba línea por línea y el rechazo llegaba recién al
 * sincronizar (#961).
 */
import type { PromoMap } from './promociones'

export interface RenglonDeStock {
  productoId: string | number
  cantidad: number
  esBonificacion?: boolean
  /**
   * Si la promo del regalo mueve stock. Se sella al encolar (la cola sólo
   * guardaba `promocionId` y offline no hay cómo preguntarle a la promo). Ausente
   * cuenta como false, igual que el `COALESCE(..., FALSE)` del servidor.
   */
  regaloMueveStock?: boolean
}

/** ¿Este renglón descuenta stock del producto al crear el pedido? */
function descuentaStock(r: RenglonDeStock): boolean {
  return !r.esBonificacion || r.regaloMueveStock === true
}

/** Unidades de cada producto que el pedido descuenta del stock (clave: id como string). */
export function cantidadesQueDescuentanStock(
  renglones: readonly RenglonDeStock[],
): Map<string, number> {
  const porProducto = new Map<string, number>()
  for (const r of renglones) {
    if (!descuentaStock(r)) continue
    const cantidad = Number(r.cantidad)
    if (!Number.isFinite(cantidad) || cantidad <= 0) continue
    const id = String(r.productoId)
    porProducto.set(id, (porProducto.get(id) ?? 0) + cantidad)
  }
  return porProducto
}

/**
 * Índice promoción → ¿su regalo mueve stock?, para sellar `regaloMueveStock` en
 * las líneas de regalo al encolar. Una promo aparece bajo cada producto que la
 * dispara: acá se aplana por id.
 */
export function indexarRegaloMueveStock(promoMap: PromoMap | undefined): Map<string, boolean> {
  const indice = new Map<string, boolean>()
  for (const promos of promoMap?.values() ?? []) {
    for (const promo of promos) indice.set(String(promo.id), promo.regaloMueveStock === true)
  }
  return indice
}

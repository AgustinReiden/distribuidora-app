/**
 * El piso de la cantidad de un producto al EDITAR un pedido (H1 de la revisión de B23, #1603).
 *
 * La política rige el alta: un producto que el pedido ya tenía debajo de un mínimo de venta que
 * subió después se sigue editando mientras no baje (`moqQueBloqueaLaEdicion`, la regla del server
 * `validar_minimo_venta_item`). El campo de la cantidad no puede poner en rojo lo que esa regla
 * deja guardar: su `min` sale de acá, y acá sale de esa regla, no de una copia de la fórmula.
 *
 * Vive fuera de `precioMayorista.ts` porque ese archivo tiene copia espejo en el bot.
 */
import { moqQueBloqueaLaEdicion } from './precioMayorista'

/**
 * La menor cantidad del producto que la edición deja guardar: el mínimo de venta de hoy, o lo que
 * el pedido ya tenía si era menos. `cantidadesOriginales` es lo que el pedido tenía de cada
 * producto en líneas de venta, sumadas (`cantidadesPorProducto`).
 */
export function pisoDeVentaEnLaEdicion(
  productoId: string | number,
  minimoDeVenta: number,
  cantidadesOriginales: Map<string, number>,
): number {
  const pid = String(productoId)
  const bloquea = (cantidad: number): boolean =>
    cantidad < minimoDeVenta
    && moqQueBloqueaLaEdicion([{ productoId: pid, cantidadActual: cantidad, cantidadMinima: minimoDeVenta }], cantidadesOriginales).length > 0
  // Lo que la regla deja pasar es [piso, ∞), y el piso es lo que ya tenía o el mínimo de hoy.
  const original = cantidadesOriginales.get(pid) ?? 0
  return original >= 1 && original < minimoDeVenta && !bloquea(original) ? original : minimoDeVenta
}

/** El motivo del rojo bajo ese piso: dice el mínimo de hoy y, si rige otro, lo que el pedido ya tenía. */
export function motivoPisoDeVentaEnLaEdicion(minimoDeVenta: number, piso: number): string | undefined {
  if (minimoDeVenta <= 1) return undefined
  return piso < minimoDeVenta
    ? `El mínimo de venta es ${minimoDeVenta}; este pedido ya tenía ${piso}`
    : `El mínimo de venta es ${minimoDeVenta}`
}

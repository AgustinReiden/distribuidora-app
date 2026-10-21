/**
 * Qué es un producto "sin precio de venta".
 *
 * `productos.precio` es NOT NULL, así que "sin precio" se escribe 0: es el
 * estado "pendiente de carga de precio de venta" que muestra Productos en rojo.
 * El trigger `validar_precio_item_pedido` (mig 139, con la excepción VB de la
 * 317) rechaza el alta de una línea de venta de un producto así, para todos
 * los roles. No aplica al regalo (va a 0 por diseño) ni al vale blanco (va a
 * costo, no a lista). Hasta que el admin le carga el precio no lo vende nadie:
 * ni el preventista, ni el encargado, ni el admin. Y el alta de un producto
 * así avisa a admins y encargados (`notificar_producto_sin_precio`, mig 139).
 *
 * Por eso un alta que no sabe el precio (el producto rápido de la compra) lo
 * deja en 0 y no lo inventa: precargarlo con el costo era un precio válido para
 * todo el sistema y el preventista vendía al costo.
 */

/** El valor que significa "todavía no tiene precio de venta". */
export const PRECIO_PENDIENTE = 0

/** `true` si el producto tiene un precio de venta cargado (> 0). */
export function tienePrecioDeVenta(producto: { precio?: number | string | null }): boolean {
  return Number(producto.precio) > 0
}

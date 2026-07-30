/**
 * Helpers de movimientos entre sucursales.
 */

/**
 * Stock que la sucursal origen puede poner en un envío para un producto.
 *
 * Al CREAR es simplemente el stock actual. Al EDITAR hay una trampa: desde la
 * mig 139 el envío YA descontó su cantidad del stock, así que `producto.stock`
 * viene deflactado por este mismo envío. El tope real es lo que queda en
 * góndola MÁS lo que este envío ya se llevó — si no, editar un envío de 100 u.
 * sobre un producto que quedó en 0 mostraría tope 0 y no se podría ni bajar la
 * cantidad.
 *
 * @param stockActual        `productos.stock` tal como viene de la base
 * @param cantidadEnEsteEnvio unidades que este envío ya tiene reservadas del
 *                            producto (0 al crear, o para una línea nueva)
 */
export function stockDisponibleParaEnvio(stockActual: number, cantidadEnEsteEnvio = 0): number {
  const stock = Number.isFinite(stockActual) ? stockActual : 0
  const reservado = Number.isFinite(cantidadEnEsteEnvio) ? cantidadEnEsteEnvio : 0
  return Math.max(0, stock + reservado)
}

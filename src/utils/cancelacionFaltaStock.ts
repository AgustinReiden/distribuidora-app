/**
 * Cancelación por falta de stock (#827, mig 269).
 *
 * El stock de un pedido sale al CREARLO. Cancelar lo devuelve, salvo con el
 * motivo `falta_stock`: ahí la mercadería no existe físicamente, así que
 * `cancelar_pedido_con_stock` la devuelve y la merma en el mismo movimiento
 * (neto cero, una merma `error_inventario` por producto). Si la devolviera,
 * aparecerían unidades fantasma — caso #6415.
 *
 * Esto es el espejo en el front de qué renglones entran en esa merma, para
 * que la confirmación del modal liste exactamente lo que no vuelve al stock.
 * Mismo criterio que el SQL: un renglón normal siempre movió stock; un regalo
 * sólo si su promo tiene `regalo_mueve_stock`. Agrupado por producto, igual
 * que la merma.
 */
import type { PedidoItemDB } from '../types'

export const MOTIVO_FALTA_STOCK = 'falta_stock'

export interface UnidadQueNoVuelve {
  productoId: string
  nombre: string
  cantidad: number
}

/** ¿Este renglón descontó stock al crear el pedido? */
export function renglonMovioStock(item: PedidoItemDB): boolean {
  if (!item.es_bonificacion) return true
  return item.promocion?.regalo_mueve_stock === true
}

/** Lo que, cancelando por falta de stock, se merma en vez de volver al stock. */
export function unidadesQueNoVuelvenAlStock(items: readonly PedidoItemDB[] | null | undefined): UnidadQueNoVuelve[] {
  const porProducto = new Map<string, UnidadQueNoVuelve>()
  for (const item of items ?? []) {
    if (!renglonMovioStock(item)) continue
    const cantidad = Number(item.cantidad) || 0
    if (cantidad <= 0) continue
    const productoId = String(item.producto_id)
    const previo = porProducto.get(productoId)
    if (previo) {
      previo.cantidad += cantidad
    } else {
      porProducto.set(productoId, {
        productoId,
        nombre: item.producto?.nombre || `Producto #${productoId}`,
        cantidad,
      })
    }
  }
  return [...porProducto.values()]
}

/**
 * ¿El pedido tiene un regalo de promoción? Si la promo es de ajuste automático,
 * el regalo pudo haber abierto un fardo del contenedor; y si ese contenedor es
 * un producto del pedido, con `falta_stock` el fardo tampoco vuelve (mig 269).
 * Cuántas unidades depende de `usos_pendientes` de la promo, que el front no
 * tiene: por eso la confirmación avisa en vez de listarlo.
 */
export function tieneRegaloConPromo(items: readonly PedidoItemDB[] | null | undefined): boolean {
  return (items ?? []).some(i => i.es_bonificacion === true && i.promocion_id != null)
}

/** Texto del toast al cancelar, según el motivo elegido. */
export function mensajeCancelacion(tipo: string | null | undefined): string {
  return tipo === MOTIVO_FALTA_STOCK
    ? 'Pedido cancelado por falta de stock: la mercadería no volvió al stock y quedó registrada como merma'
    : 'Pedido cancelado y stock restaurado'
}

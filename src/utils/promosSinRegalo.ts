/**
 * Las promos que dispararían con las líneas de un pedido guardado pero de las que el pedido no
 * tiene regalo (PRM-2, #1515).
 *
 * Quitar una promo al cargar el pedido no deja rastro en ningún lado: el pedido queda sin su regalo
 * y nada más. Al editarlo o al cambiarle el cliente, el modal recalcula las promos y la promo vuelve
 * a disparar: aparecía el regalo y se guardaba solo (bajaba stock, sumaba a la barra y consumía
 * cupo), aunque se tocara sólo una nota. Por eso un pedido que ya existe no gana un regalo que no
 * tenía salvo que el usuario lo pida: estas promos arrancan quitadas.
 *
 * Se mira con las líneas del pedido como está guardado, no con lo que se va editando: una promo que
 * empieza a disparar porque el usuario agregó productos sí aplica, como en el alta.
 */
import { resolverPromociones, type PromoMap } from './promociones'
import type { ItemPedido } from './precioMayorista'

export interface PromoSinRegalo {
  promoId: string
  promoNombre: string
}

export function promosSinRegaloEnElPedido(
  itemsVenta: readonly ItemPedido[],
  promoMap: PromoMap | undefined,
  /** Las promos de las que el pedido tiene regalo (`promosConRegalo`). */
  promosDelPedido: readonly string[],
): PromoSinRegalo[] {
  if (!promoMap || itemsVenta.length === 0) return []
  const conRegalo = new Set(promosDelPedido.map(String))
  const porPromo = new Map<string, PromoSinRegalo>()
  for (const b of resolverPromociones([...itemsVenta], promoMap).bonificaciones) {
    const promoId = String(b.promoId)
    if (conRegalo.has(promoId) || porPromo.has(promoId)) continue
    porPromo.set(promoId, { promoId, promoNombre: b.promoNombre })
  }
  return [...porPromo.values()]
}

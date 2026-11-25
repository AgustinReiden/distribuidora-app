/**
 * El regalo DEL PEDIDO para una promo (N1 de la segunda lente de promos, tanda 6 bis de
 * #1603). Decisión del dueño: el regalo del pedido es el que la promo daba cuando el
 * pedido nació, no el que da hoy. La edición lo conserva por su override (el producto de
 * la línea); cuando no puede —un reparto en sabores que ya no cierra con la venta nueva—
 * `orquestarPrecios` deja el regalo de HOY de la promo, y si el admin lo había cambiado
 * (R por P), la edición pasaba R a P sin que nadie lo pidiera.
 *
 * Esto da el producto al que vuelve: la raíz de la cadena de la primera línea de la
 * promo en el pedido (las partes de un reparto y los sustitutos cuelgan del regalo con
 * que la promo se armó), o su producto si no tiene cadena. El server lo acepta en una
 * promo que el pedido ya tenía (`regalo_fuera_de_promo`, paso 3). Un regalo nuevo (la
 * promo no estaba en el pedido) toma el de hoy: acá no hay líneas y da null.
 */
import { raizDeSustitucion, type SustitucionRegistrada } from './repartoRegalo'

export interface LineaRegaloDelPedido {
  id?: string | number | null
  producto_id: string | number
  promocion_id?: string | number | null
  regalo_cadena_id?: string | null
  es_bonificacion?: boolean | null
}

export function regaloDelPedidoParaPromo(
  lineas: readonly LineaRegaloDelPedido[],
  sustitucionesDesc: SustitucionRegistrada[],
  promoId: string | number,
): string | null {
  const deLaPromo = lineas
    .filter(l => l.es_bonificacion && l.promocion_id != null && String(l.promocion_id) === String(promoId))
    .sort((a, b) => Number(a.id ?? 0) - Number(b.id ?? 0))
  const primera = deLaPromo[0]
  if (!primera) return null
  return raizDeSustitucion(sustitucionesDesc, primera.promocion_id, primera.regalo_cadena_id ?? null, primera.producto_id)
    ?? String(primera.producto_id)
}

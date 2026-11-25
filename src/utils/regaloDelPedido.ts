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
 * que la promo se armó), o su producto si no tiene cadena. Pero sólo si es lo que el
 * server acepta por N1 (`regalo_fuera_de_promo`, paso 3): el regalo de referencia del
 * pedido (`regalo_referencia_de_linea`) o uno de su rubro. Si no —la raíz es un regalo de
 * otro rubro que eligió un admin, o la pantalla no sabe la referencia (la RPC es de admin y
 * encargado)—, null: queda el regalo de hoy, como en la 545. Un regalo nuevo (la promo no
 * estaba en el pedido) toma el de hoy: acá no hay líneas y da null.
 */
import { raizDeSustitucion, type SustitucionRegistrada } from './repartoRegalo'
import { esRegaloCompatible, type ProductoRegalo } from './regaloCompatible'

export interface LineaRegaloDelPedido {
  id?: string | number | null
  producto_id: string | number
  promocion_id?: string | number | null
  regalo_cadena_id?: string | null
  es_bonificacion?: boolean | null
}

/** La primera línea de regalo de la promo en el pedido (por id), o undefined. */
export function primeraLineaDeLaPromo(
  lineas: readonly LineaRegaloDelPedido[],
  promoId: string | number,
): LineaRegaloDelPedido | undefined {
  return lineas
    .filter(l => l.es_bonificacion && l.promocion_id != null && String(l.promocion_id) === String(promoId))
    .sort((a, b) => Number(a.id ?? 0) - Number(b.id ?? 0))[0]
}

export function regaloDelPedidoParaPromo(
  lineas: readonly LineaRegaloDelPedido[],
  sustitucionesDesc: SustitucionRegistrada[],
  promoId: string | number,
  /** El regalo de referencia del pedido para la promo; null si no se sabe. */
  referencia: ProductoRegalo | null | undefined,
  productoPorId: (id: string) => ProductoRegalo | undefined,
): string | null {
  const primera = primeraLineaDeLaPromo(lineas, promoId)
  if (!primera || !referencia) return null
  const raiz = raizDeSustitucion(sustitucionesDesc, primera.promocion_id, primera.regalo_cadena_id ?? null, primera.producto_id)
    ?? String(primera.producto_id)
  if (raiz === String(referencia.id)) return raiz
  const producto = productoPorId(raiz)
  return producto && esRegaloCompatible(referencia, producto) ? raiz : null
}

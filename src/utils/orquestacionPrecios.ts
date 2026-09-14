/**
 * Orquestación de precios de un pedido.
 *
 * Un pedido tiene tres capas de precio y el ORDEN entre ellas es la regla de
 * negocio, no un detalle de implementación:
 *
 *   1. Promociones — la promo que DISPARA reclama sus productos (bonificación).
 *   2. Mayorista — sobre los items que NO quedaron reclamados por una promo.
 *   3. Descuento del cliente — general o por categoría, sobre el precio ya resuelto.
 *
 * Hasta esta función cada consumidor armaba la secuencia por su cuenta: la app
 * en `usePromocionPedido` + `aplicarDescuentoClienteItems`, y el bot de Telegram
 * en `previsualizar_pedido`. Los utils de cada capa ya estaban sincronizados
 * byte a byte entre `src/utils/` y `supabase/functions/_shared/utils/`, pero la
 * secuencia no: el bot resolvía mayorista también sobre los productos con promo
 * y nunca aplicaba el descuento del cliente, así que el mismo pedido daba dos
 * totales distintos según entrara por app o por Telegram — y
 * `crear_pedido_completo_bot` copia el total de la previsualización tal cual.
 *
 * Es pura a propósito: no toca red, ni React, ni Supabase. Los dos lados le
 * pasan los mismos mapas y tienen que recibir el mismo total.
 */

import {
  resolverPreciosMayorista,
  type ItemPedido,
  type PrecioResuelto,
  type PricingMap,
} from './precioMayorista'
import {
  resolverPromociones,
  type PromoMap,
  type PromoResolucion,
} from './promociones'
import {
  aplicarDescuentoClienteItems,
  esDescuentoDeCategoria,
  resolverDescuentoPctCliente,
  type ClienteConDescuentos,
  type ProductoConCategoria,
} from './descuentoCliente'

// =============================================================================
// TIPOS
// =============================================================================

/** Item del pedido ya resuelto. Las bonificaciones vienen como items a precio 0. */
export interface ItemResuelto extends ItemPedido {
  esBonificacion?: boolean
  promoNombre?: string
  promoId?: string
  descripcionRegalo?: string
  unidadesPorBloque?: number
}

/** Override del producto del regalo de una promo (admin lo elige al crear el pedido). */
export interface RegaloOverride {
  productoId: string
  descripcionRegalo?: string
}

export interface OrquestacionPreciosInput {
  items: ItemPedido[]
  /** Promos vigentes por productoId. Sin mapa = pedido sin promos. */
  promoMap?: PromoMap | null
  /** Condiciones mayoristas por productoId. Sin mapa = pedido sin escalas. */
  pricingMap?: PricingMap | null
  /** Productos referenciados: sólo se usa `categoria`, para el descuento por categoría. */
  productos?: ProductoConCategoria[]
  /** Cliente del pedido: descuento general + descuentos por categoría. */
  cliente?: ClienteConDescuentos | null
  /** Promos que el usuario quitó a mano: no bonifican y liberan sus disparadores. */
  promosEliminadas?: ReadonlySet<string>
  /** Producto de regalo elegido a mano, por promoId. */
  overridesRegalo?: Record<string, RegaloOverride>
}

export interface OrquestacionPreciosResult {
  /** Bonificaciones + productos reclamados por las promos que disparan. */
  promoResolucion: PromoResolucion
  /** Salida de `resolverPreciosMayorista` (sólo sobre los items sin promo aplicada). */
  preciosResueltos: Map<string, PrecioResuelto>
  /**
   * Items + bonificaciones con promo y mayorista aplicados, ANTES del descuento
   * del cliente. Es el input de `construirOrigenPrecioItems`: el descuento del
   * cliente cambia el número, no quién decidió el precio.
   */
  itemsSinDescuentoCliente: ItemResuelto[]
  /** Los mismos items con el descuento del cliente ya aplicado. Es lo que se persiste. */
  items: ItemResuelto[]
  /** Suma de los items a precio de lista (sin promo, sin mayorista, sin descuento). */
  totalOriginal: number
  /** Total después de promo + mayorista, antes del descuento del cliente. */
  totalSinDescuentoCliente: number
  /** Total final, con las tres capas aplicadas. */
  total: number
  /** totalOriginal − total. */
  ahorro: number
  /** Hubo promo aplicada o algún precio mayorista. */
  hayDescuentoPrecios: boolean
  /** El descuento del cliente bajó al menos un precio. */
  hayDescuentoCliente: boolean
  /** % de descuento del cliente por productoId (para etiquetar el origen del precio). */
  descuentoClientePct: Map<string, number>
  /** productoIds cuyo descuento salió de una regla por categoría, no del general. */
  descuentoPorCategoria: Set<string>
}

// =============================================================================
// FUNCIÓN PRINCIPAL
// =============================================================================

export function orquestarPrecios(
  input: OrquestacionPreciosInput,
): OrquestacionPreciosResult {
  const {
    items,
    promoMap,
    pricingMap,
    productos = [],
    cliente = null,
    promosEliminadas,
    overridesRegalo,
  } = input

  // ---- 1. Promociones -------------------------------------------------------
  let promoResolucion: PromoResolucion =
    promoMap && promoMap.size > 0 && items.length > 0
      ? resolverPromociones(items, promoMap, promosEliminadas)
      : { bonificaciones: [], productosConPromo: new Set<string>() }

  // El override sólo cambia el producto/descripción del regalo: los
  // disparadores (productosConPromo) y las reglas no se tocan.
  if (overridesRegalo && Object.keys(overridesRegalo).length > 0) {
    promoResolucion = {
      productosConPromo: promoResolucion.productosConPromo,
      bonificaciones: promoResolucion.bonificaciones.map(b => {
        const ov = overridesRegalo[String(b.promoId)]
        return ov
          ? { ...b, productoId: ov.productoId, descripcionRegalo: ov.descripcionRegalo }
          : b
      }),
    }
  }

  // ---- 2. Mayorista ---------------------------------------------------------
  // Se excluyen SÓLO los productos que reclamó una promo aplicada. Un producto
  // que está en una promo que no disparó sigue acá, y por lo tanto su cantidad
  // le sigue sumando la escala al resto del grupo (fardo surtido).
  const itemsSinPromo = items.filter(
    i => !promoResolucion.productosConPromo.has(String(i.productoId)),
  )
  const preciosResueltos =
    pricingMap && pricingMap.size > 0 && itemsSinPromo.length > 0
      ? resolverPreciosMayorista(itemsSinPromo, pricingMap)
      : new Map<string, PrecioResuelto>()

  // ---- 3. Items resueltos (compra + regalos) --------------------------------
  const itemsSinDescuentoCliente: ItemResuelto[] = []
  let totalOriginal = 0
  let totalSinDescuentoCliente = 0

  for (const item of items) {
    const pid = String(item.productoId)
    totalOriginal += item.precioUnitario * item.cantidad

    const mayorista = preciosResueltos.get(pid)
    const precioUnitario = mayorista && mayorista.esMayorista && !item.precioOverride
      ? mayorista.precioResuelto
      : item.precioUnitario

    totalSinDescuentoCliente += precioUnitario * item.cantidad
    itemsSinDescuentoCliente.push({ ...item, precioUnitario })
  }

  for (const bonif of promoResolucion.bonificaciones) {
    itemsSinDescuentoCliente.push({
      productoId: String(bonif.productoId),
      cantidad: bonif.cantidadBonificacion,
      precioUnitario: 0,
      esBonificacion: true,
      promoNombre: bonif.promoNombre,
      promoId: bonif.promoId,
      descripcionRegalo: bonif.descripcionRegalo,
      unidadesPorBloque: bonif.unidadesPorBloque,
    })
  }

  // ---- 4. Descuento del cliente --------------------------------------------
  const descuento = aplicarDescuentoClienteItems(
    itemsSinDescuentoCliente,
    productos,
    cliente,
  )

  // Contexto para etiquetar el origen del precio (mig 148): el % que le tocó a
  // cada producto y si salió de una regla por categoría o del general.
  const descuentoClientePct = new Map<string, number>()
  const descuentoPorCategoria = new Set<string>()
  for (const item of itemsSinDescuentoCliente) {
    const pid = String(item.productoId)
    if (descuentoClientePct.has(pid)) continue
    const categoria = productos.find(p => String(p.id) === pid)?.categoria
    descuentoClientePct.set(pid, resolverDescuentoPctCliente(cliente, categoria))
    if (esDescuentoDeCategoria(cliente, categoria)) descuentoPorCategoria.add(pid)
  }

  let hayDescuentoPrecios = promoResolucion.bonificaciones.length > 0
  if (!hayDescuentoPrecios) {
    for (const r of preciosResueltos.values()) {
      if (r.esMayorista) {
        hayDescuentoPrecios = true
        break
      }
    }
  }

  return {
    promoResolucion,
    preciosResueltos,
    itemsSinDescuentoCliente,
    items: descuento.items,
    totalOriginal,
    totalSinDescuentoCliente,
    total: descuento.total,
    ahorro: totalOriginal - descuento.total,
    hayDescuentoPrecios,
    hayDescuentoCliente: descuento.hayDescuento,
    descuentoClientePct,
    descuentoPorCategoria,
  }
}

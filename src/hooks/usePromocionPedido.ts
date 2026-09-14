/**
 * Hook reactivo para resolución de promociones + precios mayoristas
 *
 * La secuencia promo → mayorista → descuento del cliente NO vive acá: vive en
 * `utils/orquestacionPrecios.ts`, que está sincronizado byte a byte con la copia
 * del bot de Telegram. Este hook sólo conecta las queries (pricingMap, promoMap,
 * mínimos de venta) con esa función pura y expone los nudges, que son de la app.
 */
import { useMemo } from 'react'
import { usePricingMapQuery } from './queries/useGruposPrecioQuery'
import { usePromoMapQuery } from './queries/usePromocionesQuery'
import { useMinimosVentaQuery } from './queries/useProductosQuery'
import {
  calcularFaltanteParaTier,
  construirMOQMap,
  validarMOQPedido,
  type ItemPedido,
  type MinimosProducto,
  type PrecioResuelto,
  type FaltanteParaTier,
  type ViolacionMOQ,
} from '../utils/precioMayorista'
import {
  calcularFaltanteParaBonificacion,
  type PromoResolucion,
} from '../utils/promociones'
import {
  orquestarPrecios,
  type ItemResuelto,
  type RegaloOverride,
} from '../utils/orquestacionPrecios'
import type { ClienteConDescuentos, ProductoConCategoria } from '../utils/descuentoCliente'

/** Item del pedido ya resuelto (compra o regalo). Alias del tipo de la orquestación. */
export type ItemPedidoConPromo = ItemResuelto

export type { RegaloOverride }

/**
 * Cliente + catálogo para la tercera capa (descuento general / por categoría).
 * Es opcional: las pantallas que sólo muestran promo + mayorista (edición de un
 * pedido ya guardado, por ejemplo) no lo pasan y el hook se queda en dos capas.
 */
export interface ContextoDescuentoCliente {
  cliente?: ClienteConDescuentos | null
  productos?: ProductoConCategoria[]
}

interface UsePromocionPedidoReturn {
  /** Mapa de productoId → precio resuelto (mayorista) */
  preciosResueltos: Map<string, PrecioResuelto>
  /** Nudges de mayorista */
  faltantes: FaltanteParaTier[]
  /** Resolución de promociones */
  promoResolucion: PromoResolucion
  /** Nudges de bonificación */
  faltantesBonificacion: Array<{ productoId: string; promoNombre: string; faltante: number; bonificacion: number }>
  /** Items finales con bonificaciones añadidas, SIN el descuento del cliente */
  itemsFinales: ItemPedidoConPromo[]
  /** Total calculado correctamente con promos, SIN el descuento del cliente */
  totalFinal: number
  /** Total original sin ningún descuento */
  totalOriginal: number
  /** Ahorro total (sin contar el descuento del cliente) */
  ahorro: number
  /** Si hay al menos un item con precio mayorista o promo */
  hayDescuento: boolean
  /**
   * Los mismos `itemsFinales` con el descuento del cliente ya aplicado. Es lo
   * que hay que persistir. Sin `contextoDescuento`, es igual a `itemsFinales`.
   */
  itemsConDescuentoCliente: ItemPedidoConPromo[]
  /** Total con las tres capas aplicadas. Es el total que se guarda. */
  totalConDescuentoCliente: number
  /** El descuento del cliente bajó al menos un precio */
  hayDescuentoCliente: boolean
  /** Promo/mayorista o descuento del cliente: alguno bajó un precio */
  hayDescuentoTotal: boolean
  /** % de descuento del cliente por productoId (para `construirOrigenPrecioItems`) */
  descuentoClientePct: Map<string, number>
  /** productoIds cuyo descuento salió de una regla por categoría, no del general */
  descuentoPorCategoria: Set<string>
  /** Loading */
  isLoading: boolean
  /**
   * Mapa MOQ de los items QUE YA ESTÁN EN EL CARRITO (`construirMOQMap` itera
   * `items`). Para un producto del catálogo todavía no agregado da `undefined`;
   * para eso está `minimosProducto`.
   */
  moqMap: Map<string, number>
  /**
   * Mínimo de venta de TODOS los productos (mig 147). Es lo que hay que
   * consultar en el listado del catálogo, con `obtenerMOQ(id, minimosProducto)`:
   * usar `moqMap` ahí devolvía undefined y el producto entraba al carrito con
   * cantidad 1, en violación de su propio mínimo y con el confirmar bloqueado.
   */
  minimosProducto?: MinimosProducto
  /** Violaciones MOQ */
  violacionesMOQ: ViolacionMOQ[]
}

export function usePromocionPedido(
  items: ItemPedido[],
  fechaReferencia?: string,
  /** Override del producto del regalo por promoId. El admin puede elegir otro
   *  producto para la bonificación al crear el pedido (paridad con "Cambiar
   *  regalo" de la edición). */
  overridesRegalo?: Record<string, RegaloOverride>,
  /** Ids de promos que el usuario quitó a mano (crear/editar). Se excluyen de la
   *  resolución: sin regalo y con los disparadores liberados para mayorista. */
  promosEliminadas?: ReadonlySet<string>,
  /** Cliente + catálogo para aplicar la tercera capa de precio. */
  contextoDescuento?: ContextoDescuentoCliente,
): UsePromocionPedidoReturn {
  const { data: pricingMap, isLoading: loadingPricing } = usePricingMapQuery()
  const { data: promoMap, isLoading: loadingPromos } = usePromoMapQuery(fechaReferencia)
  // Mínimo de venta propio del producto (mig 147), independiente de las
  // condiciones mayoristas.
  const { data: minimosProducto } = useMinimosVentaQuery()

  // Se desestructura para depender de los valores y no de la identidad del
  // objeto literal, que cambia en cada render del componente que llama.
  const cliente = contextoDescuento?.cliente ?? null
  const productos = contextoDescuento?.productos

  // Promo → mayorista → descuento del cliente, en una sola pasada y con la
  // misma función que usa el bot.
  const orquestacion = useMemo(
    () => orquestarPrecios({
      items,
      promoMap,
      pricingMap,
      productos,
      cliente,
      promosEliminadas,
      overridesRegalo,
    }),
    [items, promoMap, pricingMap, productos, cliente, promosEliminadas, overridesRegalo],
  )

  // Nudges de mayorista: sobre los items que la promo no reclamó, igual que la
  // resolución de precios.
  const faltantes = useMemo(() => {
    if (!pricingMap || pricingMap.size === 0 || items.length === 0) return []
    const itemsSinPromo = items.filter(
      i => !orquestacion.promoResolucion.productosConPromo.has(String(i.productoId))
    )
    return calcularFaltanteParaTier(itemsSinPromo, pricingMap)
  }, [items, pricingMap, orquestacion.promoResolucion.productosConPromo])

  const faltantesBonificacion = useMemo(() => {
    if (!promoMap || promoMap.size === 0 || items.length === 0) return []
    return calcularFaltanteParaBonificacion(items, promoMap)
  }, [items, promoMap])

  // MOQ — el mínimo de venta es del producto (mig 147/169), independiente
  // de que tenga o no una condición mayorista.
  const moqMap = useMemo(() => {
    if (items.length === 0) return new Map<string, number>()
    return construirMOQMap(items, minimosProducto)
  }, [items, minimosProducto])

  const violacionesMOQ = useMemo(() => {
    if (items.length === 0) return []
    return validarMOQPedido(items, minimosProducto)
  }, [items, minimosProducto])

  return {
    preciosResueltos: orquestacion.preciosResueltos,
    faltantes,
    promoResolucion: orquestacion.promoResolucion,
    faltantesBonificacion,
    itemsFinales: orquestacion.itemsSinDescuentoCliente,
    totalFinal: orquestacion.totalSinDescuentoCliente,
    totalOriginal: orquestacion.totalOriginal,
    ahorro: orquestacion.totalOriginal - orquestacion.totalSinDescuentoCliente,
    hayDescuento: orquestacion.hayDescuentoPrecios,
    itemsConDescuentoCliente: orquestacion.items,
    totalConDescuentoCliente: orquestacion.total,
    hayDescuentoCliente: orquestacion.hayDescuentoCliente,
    hayDescuentoTotal: orquestacion.hayDescuentoPrecios || orquestacion.hayDescuentoCliente,
    descuentoClientePct: orquestacion.descuentoClientePct,
    descuentoPorCategoria: orquestacion.descuentoPorCategoria,
    isLoading: loadingPricing || loadingPromos,
    moqMap,
    minimosProducto,
    violacionesMOQ,
  }
}

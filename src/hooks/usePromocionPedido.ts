/**
 * Hook reactivo para resolución de promociones + precios mayoristas
 *
 * Orquesta:
 * 1. Promos activas (bonificación, precio por pares)
 * 2. Precios mayoristas (excluyendo productos con promo)
 * 3. Genera items finales con bonificaciones incluidas
 * 4. Calcula totales correctos
 */
import { useMemo } from 'react'
import { usePricingMapQuery } from './queries/useGruposPrecioQuery'
import { usePromoMapQuery } from './queries/usePromocionesQuery'
import {
  resolverPreciosMayorista,
  calcularFaltanteParaTier,
  construirMOQMap,
  validarMOQPedido,
  type ItemPedido,
  type PrecioResuelto,
  type FaltanteParaTier,
  type ViolacionMOQ,
} from '../utils/precioMayorista'
import {
  resolverPromociones,
  calcularFaltanteParaBonificacion,
  type PromoResolucion,
  type BonificacionResult,
  type PrecioParResult,
} from '../utils/promociones'

export interface ItemPedidoConPromo extends ItemPedido {
  esBonificacion?: boolean
  subtotalOverride?: number
  promoDetalle?: string
  promoNombre?: string
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
  /** Items finales con bonificaciones añadidas y precios ajustados */
  itemsFinales: ItemPedidoConPromo[]
  /** Total calculado correctamente con promos */
  totalFinal: number
  /** Total original sin ningún descuento */
  totalOriginal: number
  /** Ahorro total */
  ahorro: number
  /** Si hay al menos un item con precio mayorista o promo */
  hayDescuento: boolean
  /** Loading */
  isLoading: boolean
  /** Mapa MOQ */
  moqMap: Map<string, number>
  /** Violaciones MOQ */
  violacionesMOQ: ViolacionMOQ[]
}

export function usePromocionPedido(items: ItemPedido[]): UsePromocionPedidoReturn {
  const { data: pricingMap, isLoading: loadingPricing } = usePricingMapQuery()
  const { data: promoMap, isLoading: loadingPromos } = usePromoMapQuery()

  // 1. Resolver promociones
  const promoResolucion = useMemo((): PromoResolucion => {
    if (!promoMap || promoMap.size === 0 || items.length === 0) {
      return { bonificaciones: [], preciosPar: new Map(), productosConPromo: new Set() }
    }
    return resolverPromociones(items, promoMap)
  }, [items, promoMap])

  // 2. Resolver mayorista EXCLUYENDO productos con promo
  const preciosResueltos = useMemo(() => {
    if (!pricingMap || pricingMap.size === 0 || items.length === 0) {
      return new Map<string, PrecioResuelto>()
    }
    // Filtrar items que NO tienen promo para resolver mayorista
    const itemsSinPromo = items.filter(
      i => !promoResolucion.productosConPromo.has(String(i.productoId))
    )
    if (itemsSinPromo.length === 0) return new Map<string, PrecioResuelto>()
    return resolverPreciosMayorista(itemsSinPromo, pricingMap)
  }, [items, pricingMap, promoResolucion.productosConPromo])

  // 3. Nudges mayorista
  const faltantes = useMemo(() => {
    if (!pricingMap || pricingMap.size === 0 || items.length === 0) return []
    const itemsSinPromo = items.filter(
      i => !promoResolucion.productosConPromo.has(String(i.productoId))
    )
    return calcularFaltanteParaTier(itemsSinPromo, pricingMap)
  }, [items, pricingMap, promoResolucion.productosConPromo])

  // 4. Nudges bonificación
  const faltantesBonificacion = useMemo(() => {
    if (!promoMap || promoMap.size === 0 || items.length === 0) return []
    return calcularFaltanteParaBonificacion(items, promoMap)
  }, [items, promoMap])

  // 5. Construir items finales
  const itemsFinales = useMemo((): ItemPedidoConPromo[] => {
    const result: ItemPedidoConPromo[] = []

    for (const item of items) {
      const pid = String(item.productoId)
      const precioParResult = promoResolucion.preciosPar.get(pid)
      const precioMayorista = preciosResueltos.get(pid)

      if (precioParResult) {
        // Producto con promo de precio por pares
        result.push({
          ...item,
          subtotalOverride: precioParResult.subtotalPromo,
          promoDetalle: precioParResult.detalle,
          promoNombre: precioParResult.promoNombre,
        })
      } else if (precioMayorista && precioMayorista.esMayorista && !item.precioOverride) {
        // Producto con precio mayorista (sin promo)
        result.push({
          ...item,
          precioUnitario: precioMayorista.precioResuelto,
        })
      } else {
        result.push({ ...item })
      }
    }

    // Agregar items de bonificación
    for (const bonif of promoResolucion.bonificaciones) {
      result.push({
        productoId: bonif.productoId,
        cantidad: bonif.cantidadBonificacion,
        precioUnitario: 0,
        esBonificacion: true,
        promoNombre: bonif.promoNombre,
      })
    }

    return result
  }, [items, promoResolucion, preciosResueltos])

  // 6. Calcular totales
  const { totalFinal, totalOriginal } = useMemo(() => {
    let total = 0
    let original = 0

    for (const item of items) {
      const pid = String(item.productoId)
      original += item.precioUnitario * item.cantidad

      const precioParResult = promoResolucion.preciosPar.get(pid)
      if (precioParResult) {
        total += precioParResult.subtotalPromo
        continue
      }

      const precioMayorista = preciosResueltos.get(pid)
      if (precioMayorista) {
        total += precioMayorista.precioResuelto * item.cantidad
      } else {
        total += item.precioUnitario * item.cantidad
      }
    }

    return { totalFinal: total, totalOriginal: original }
  }, [items, promoResolucion.preciosPar, preciosResueltos])

  // 7. Hay descuento?
  const hayDescuento = useMemo(() => {
    if (promoResolucion.productosConPromo.size > 0) return true
    for (const [, r] of preciosResueltos) {
      if (r.esMayorista) return true
    }
    return false
  }, [promoResolucion.productosConPromo, preciosResueltos])

  // 8. MOQ
  const moqMap = useMemo(() => {
    if (!pricingMap || pricingMap.size === 0) return new Map<string, number>()
    return construirMOQMap(items, pricingMap)
  }, [items, pricingMap])

  const violacionesMOQ = useMemo(() => {
    if (!pricingMap || pricingMap.size === 0 || items.length === 0) return []
    return validarMOQPedido(items, pricingMap)
  }, [items, pricingMap])

  return {
    preciosResueltos,
    faltantes,
    promoResolucion,
    faltantesBonificacion,
    itemsFinales,
    totalFinal,
    totalOriginal,
    ahorro: totalOriginal - totalFinal,
    hayDescuento,
    isLoading: loadingPricing || loadingPromos,
    moqMap,
    violacionesMOQ,
  }
}

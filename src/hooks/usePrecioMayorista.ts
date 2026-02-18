/**
 * Hook reactivo para resolución de precios mayoristas
 *
 * Combina usePricingMapQuery + resolverPreciosMayorista
 * para recalcular precios en tiempo real según los items del pedido.
 */
import { useMemo } from 'react'
import { usePricingMapQuery } from './queries/useGruposPrecioQuery'
import {
  resolverPreciosMayorista,
  calcularFaltanteParaTier,
  aplicarPreciosMayorista,
  type ItemPedido,
  type PrecioResuelto,
  type FaltanteParaTier,
  type PricingMap
} from '../utils/precioMayorista'

interface UsePrecioMayoristaReturn {
  /** Mapa de productoId → precio resuelto */
  preciosResueltos: Map<string, PrecioResuelto>
  /** Nudges de "agrega X más para precio mayorista" */
  faltantes: FaltanteParaTier[]
  /** Items con precios mayoristas aplicados */
  itemsConPrecioMayorista: ItemPedido[]
  /** Total calculado con precios mayoristas */
  totalMayorista: number
  /** Total original sin descuentos */
  totalOriginal: number
  /** Ahorro total */
  ahorro: number
  /** Si hay al menos un item con precio mayorista */
  hayMayorista: boolean
  /** Si el pricing map está cargando */
  isLoading: boolean
}

/**
 * Hook que resuelve precios mayoristas reactivamente
 *
 * @param items - Items actuales del pedido
 * @returns Precios resueltos, nudges, items actualizados y totales
 */
export function usePrecioMayorista(items: ItemPedido[]): UsePrecioMayoristaReturn {
  const { data: pricingMap, isLoading } = usePricingMapQuery()

  const preciosResueltos = useMemo(() => {
    if (!pricingMap || pricingMap.size === 0 || items.length === 0) {
      return new Map<string, PrecioResuelto>()
    }
    return resolverPreciosMayorista(items, pricingMap)
  }, [items, pricingMap])

  const faltantes = useMemo(() => {
    if (!pricingMap || pricingMap.size === 0 || items.length === 0) {
      return []
    }
    return calcularFaltanteParaTier(items, pricingMap)
  }, [items, pricingMap])

  const itemsConPrecioMayorista = useMemo(() => {
    if (preciosResueltos.size === 0) return items
    return aplicarPreciosMayorista(items, preciosResueltos)
  }, [items, preciosResueltos])

  const { totalMayorista, totalOriginal } = useMemo(() => {
    let mayorista = 0
    let original = 0
    for (const item of items) {
      original += item.precioUnitario * item.cantidad
      const resuelto = preciosResueltos.get(item.productoId)
      if (resuelto) {
        mayorista += resuelto.precioResuelto * item.cantidad
      } else {
        mayorista += item.precioUnitario * item.cantidad
      }
    }
    return { totalMayorista: mayorista, totalOriginal: original }
  }, [items, preciosResueltos])

  const hayMayorista = useMemo(() => {
    for (const [, resuelto] of preciosResueltos) {
      if (resuelto.esMayorista) return true
    }
    return false
  }, [preciosResueltos])

  return {
    preciosResueltos,
    faltantes,
    itemsConPrecioMayorista,
    totalMayorista,
    totalOriginal,
    ahorro: totalOriginal - totalMayorista,
    hayMayorista,
    isLoading,
  }
}

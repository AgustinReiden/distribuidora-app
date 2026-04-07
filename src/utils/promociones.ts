/**
 * Utilidades para resolución de promociones temporales
 *
 * Tipos de promoción soportados:
 *   1. bonificacion: Compra X, lleva Y gratis (acumulable)
 *
 * Las promociones tienen prioridad sobre los precios mayoristas:
 * si un producto tiene promo activa, se usa la promo en vez del mayorista.
 */

import type { ItemPedido } from './precioMayorista'

// =============================================================================
// TIPOS
// =============================================================================

export interface PromocionActiva {
  id: string
  nombre: string
  tipo: 'bonificacion'
  productoIds: string[]
  reglas: Record<string, number>
}

/** Mapa de productoId → promos activas que aplican */
export type PromoMap = Map<string, PromocionActiva[]>

export interface BonificacionResult {
  productoId: string
  promoId: string
  promoNombre: string
  cantidadBonificacion: number
}

export interface PromoResolucion {
  bonificaciones: BonificacionResult[]
  productosConPromo: Set<string>
}

// =============================================================================
// FUNCIONES PRINCIPALES
// =============================================================================

/**
 * Resuelve todas las promociones activas para los items del pedido.
 *
 * @param items - Items del pedido actual
 * @param promoMap - Mapa de productoId → promos activas
 * @returns Bonificaciones a agregar y set de productos con promo
 */
export function resolverPromociones(
  items: ItemPedido[],
  promoMap: PromoMap
): PromoResolucion {
  const bonificaciones: BonificacionResult[] = []
  const productosConPromo = new Set<string>()

  for (const item of items) {
    if (item.precioOverride) continue

    const promos = promoMap.get(String(item.productoId))
    if (!promos) continue

    for (const promo of promos) {
      if (promo.tipo === 'bonificacion') {
        const result = resolverBonificacion(item, promo)
        if (result) {
          bonificaciones.push(result)
          productosConPromo.add(String(item.productoId))
        }
      }
    }
  }

  return { bonificaciones, productosConPromo }
}

// =============================================================================
// RESOLUCIÓN POR TIPO
// =============================================================================

/**
 * Resuelve una promo de bonificación para un item.
 * Acumulable: cada N unidades compradas se bonifican M.
 */
function resolverBonificacion(
  item: ItemPedido,
  promo: PromocionActiva
): BonificacionResult | null {
  const cantCompra = promo.reglas['cantidad_compra']
  const cantBonif = promo.reglas['cantidad_bonificacion']

  if (!cantCompra || !cantBonif || cantCompra <= 0) return null

  const bloques = Math.floor(item.cantidad / cantCompra)
  if (bloques <= 0) return null

  return {
    productoId: String(item.productoId),
    promoId: promo.id,
    promoNombre: promo.nombre,
    cantidadBonificacion: bloques * cantBonif,
  }
}

// =============================================================================
// HELPERS
// =============================================================================

/**
 * Calcula cuánto falta para activar una bonificación.
 * Útil para nudges tipo "agrega X más para recibir Y gratis".
 */
export function calcularFaltanteParaBonificacion(
  items: ItemPedido[],
  promoMap: PromoMap
): Array<{ productoId: string; promoNombre: string; faltante: number; bonificacion: number }> {
  const faltantes: Array<{ productoId: string; promoNombre: string; faltante: number; bonificacion: number }> = []

  for (const item of items) {
    const promos = promoMap.get(String(item.productoId))
    if (!promos) continue

    for (const promo of promos) {
      if (promo.tipo !== 'bonificacion') continue

      const cantCompra = promo.reglas['cantidad_compra']
      const cantBonif = promo.reglas['cantidad_bonificacion']
      if (!cantCompra || !cantBonif) continue

      const resto = item.cantidad % cantCompra
      if (resto === 0) continue // Ya califica exacto

      const faltante = cantCompra - resto
      // Solo mostrar nudge si falta poco (menos del 50%)
      if (faltante <= Math.ceil(cantCompra * 0.5)) {
        faltantes.push({
          productoId: String(item.productoId),
          promoNombre: promo.nombre,
          faltante,
          bonificacion: cantBonif,
        })
      }
    }
  }

  return faltantes
}

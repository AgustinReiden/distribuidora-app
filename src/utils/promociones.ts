/**
 * Utilidades para resolución de promociones temporales
 *
 * Tipos de promoción soportados:
 *   1. bonificacion: Compra X, lleva Y gratis (acumulable)
 *
 * La cantidad se acumula entre TODOS los productos de la misma promo.
 * Ejemplo: promo "Manaos 2+2" con 3 sabores → 1 de cada uno = 3 total → aplica 1 vez.
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
 * La bonificación se calcula sumando cantidades de TODOS los productos
 * que pertenecen a la misma promo (igual que las escalas mayoristas por grupo).
 * La bonificación se asigna al primer producto del pedido que pertenece a la promo.
 */
export function resolverPromociones(
  items: ItemPedido[],
  promoMap: PromoMap
): PromoResolucion {
  const bonificaciones: BonificacionResult[] = []
  const productosConPromo = new Set<string>()

  // Recolectar todas las promos únicas que aplican a items del pedido
  const promosVistas = new Map<string, { promo: PromocionActiva; totalQty: number; primerProductoId: string }>()

  for (const item of items) {
    if (item.precioOverride) continue

    const promos = promoMap.get(String(item.productoId))
    if (!promos) continue

    for (const promo of promos) {
      if (promo.tipo !== 'bonificacion') continue

      const existing = promosVistas.get(promo.id)
      if (existing) {
        existing.totalQty += item.cantidad
      } else {
        promosVistas.set(promo.id, {
          promo,
          totalQty: item.cantidad,
          primerProductoId: String(item.productoId),
        })
      }

      // Marcar este producto como parte de una promo
      productosConPromo.add(String(item.productoId))
    }
  }

  // Resolver bonificación para cada promo usando el total acumulado
  for (const [, { promo, totalQty, primerProductoId }] of promosVistas) {
    const cantCompra = promo.reglas['cantidad_compra']
    const cantBonif = promo.reglas['cantidad_bonificacion']

    if (!cantCompra || !cantBonif || cantCompra <= 0) continue

    const bloques = Math.floor(totalQty / cantCompra)
    if (bloques <= 0) continue

    bonificaciones.push({
      productoId: primerProductoId,
      promoId: promo.id,
      promoNombre: promo.nombre,
      cantidadBonificacion: bloques * cantBonif,
    })
  }

  return { bonificaciones, productosConPromo }
}

// =============================================================================
// HELPERS
// =============================================================================

/**
 * Calcula cuánto falta para activar una bonificación.
 * Usa cantidad acumulada de todos los productos de la promo.
 */
export function calcularFaltanteParaBonificacion(
  items: ItemPedido[],
  promoMap: PromoMap
): Array<{ productoId: string; promoNombre: string; faltante: number; bonificacion: number }> {
  const faltantes: Array<{ productoId: string; promoNombre: string; faltante: number; bonificacion: number }> = []

  // Acumular cantidades por promo
  const promosAcumuladas = new Map<string, { promo: PromocionActiva; totalQty: number; primerProductoId: string }>()

  for (const item of items) {
    const promos = promoMap.get(String(item.productoId))
    if (!promos) continue

    for (const promo of promos) {
      if (promo.tipo !== 'bonificacion') continue

      const existing = promosAcumuladas.get(promo.id)
      if (existing) {
        existing.totalQty += item.cantidad
      } else {
        promosAcumuladas.set(promo.id, {
          promo,
          totalQty: item.cantidad,
          primerProductoId: String(item.productoId),
        })
      }
    }
  }

  for (const [, { promo, totalQty, primerProductoId }] of promosAcumuladas) {
    const cantCompra = promo.reglas['cantidad_compra']
    const cantBonif = promo.reglas['cantidad_bonificacion']
    if (!cantCompra || !cantBonif) continue

    const resto = totalQty % cantCompra
    if (resto === 0) continue // Ya califica exacto

    const faltante = cantCompra - resto
    // Solo mostrar nudge si falta poco (menos del 50%)
    if (faltante <= Math.ceil(cantCompra * 0.5)) {
      faltantes.push({
        productoId: primerProductoId,
        promoNombre: promo.nombre,
        faltante,
        bonificacion: cantBonif,
      })
    }
  }

  return faltantes
}

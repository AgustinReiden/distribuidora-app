/**
 * Utilidades para resolución de promociones temporales
 *
 * Tipos de promoción soportados:
 *   1. bonificacion: Compra X, lleva Y gratis (acumulable)
 *   2. precio_par: Descuento por pares con umbral de precio completo
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
  tipo: 'bonificacion' | 'precio_par'
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

export interface PrecioParResult {
  productoId: string
  promoId: string
  promoNombre: string
  subtotalPromo: number
  precioEfectivo: number
  detalle: string
}

export interface PromoResolucion {
  bonificaciones: BonificacionResult[]
  preciosPar: Map<string, PrecioParResult>
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
 * @returns Bonificaciones a agregar, precios por pares ajustados, y set de productos con promo
 */
export function resolverPromociones(
  items: ItemPedido[],
  promoMap: PromoMap
): PromoResolucion {
  const bonificaciones: BonificacionResult[] = []
  const preciosPar = new Map<string, PrecioParResult>()
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

      if (promo.tipo === 'precio_par') {
        const result = resolverPrecioPar(item, promo)
        if (result) {
          preciosPar.set(String(item.productoId), result)
          productosConPromo.add(String(item.productoId))
        }
      }
    }
  }

  return { bonificaciones, preciosPar, productosConPromo }
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

/**
 * Resuelve una promo de precio por pares.
 *
 * Lógica:
 *   - qty >= umbral_todo_promo → todas las unidades al precio promo
 *   - qty < umbral → pares al precio promo, sueltas al precio regular
 */
function resolverPrecioPar(
  item: ItemPedido,
  promo: PromocionActiva
): PrecioParResult | null {
  const precioPromo = promo.reglas['precio_promo']
  const precioRegular = promo.reglas['precio_regular'] ?? item.precioUnitario
  const umbral = promo.reglas['umbral_todo_promo'] ?? Infinity

  if (precioPromo == null || precioPromo <= 0) return null
  // Solo aplicar si el precio promo es realmente menor que el regular
  if (precioPromo >= precioRegular) return null

  const qty = item.cantidad
  let subtotal: number
  let detalle: string

  if (qty >= umbral) {
    subtotal = qty * precioPromo
    detalle = `${qty}×$${formatPrecio(precioPromo)}`
  } else {
    const pares = Math.floor(qty / 2)
    const sueltas = qty % 2
    subtotal = (pares * 2 * precioPromo) + (sueltas * precioRegular)

    if (pares > 0 && sueltas > 0) {
      detalle = `${pares * 2}×$${formatPrecio(precioPromo)} + ${sueltas}×$${formatPrecio(precioRegular)}`
    } else if (pares > 0) {
      detalle = `${qty}×$${formatPrecio(precioPromo)}`
    } else {
      // Solo sueltas, no hay descuento real
      return null
    }
  }

  return {
    productoId: String(item.productoId),
    promoId: promo.id,
    promoNombre: promo.nombre,
    subtotalPromo: subtotal,
    precioEfectivo: subtotal / qty,
    detalle,
  }
}

// =============================================================================
// HELPERS
// =============================================================================

function formatPrecio(precio: number): string {
  return precio.toLocaleString('es-AR', { maximumFractionDigits: 0 })
}

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

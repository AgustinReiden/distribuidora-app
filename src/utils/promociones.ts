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
  productoRegaloId?: string
  prioridad?: number
  regaloMueveStock?: boolean
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

  // Recolectar promos vistas + qué productos del pedido las activaron (para exclusión)
  const promosVistas = new Map<string, PromoEntry>()

  for (const item of items) {
    if (item.precioOverride) continue

    const promos = promoMap.get(String(item.productoId))
    if (!promos) continue

    for (const promo of promos) {
      if (promo.tipo !== 'bonificacion') continue

      const existing = promosVistas.get(promo.id)
      if (existing) {
        existing.totalQty += item.cantidad
        existing.productoIdsEnPedido.add(String(item.productoId))
      } else {
        promosVistas.set(promo.id, {
          promo,
          totalQty: item.cantidad,
          primerProductoId: String(item.productoId),
          productoIdsEnPedido: new Set([String(item.productoId)]),
        })
      }

      productosConPromo.add(String(item.productoId))
    }
  }

  // Exclusión: entre promos que compiten por el mismo producto, gana la de mayor prioridad
  const resueltas = resolverConflictos(promosVistas)

  for (const { promo, totalQty, primerProductoId } of resueltas) {
    const cantCompra = promo.reglas['cantidad_compra']
    const cantBonif = promo.reglas['cantidad_bonificacion']

    if (!cantCompra || !cantBonif || cantCompra <= 0) continue

    const bloques = Math.floor(totalQty / cantCompra)
    if (bloques <= 0) continue

    bonificaciones.push({
      productoId: promo.productoRegaloId || primerProductoId,
      promoId: promo.id,
      promoNombre: promo.nombre,
      cantidadBonificacion: bloques * cantBonif,
    })
  }

  return { bonificaciones, productosConPromo }
}

// =============================================================================
// EXCLUSIÓN POR PRIORIDAD
// =============================================================================

interface PromoEntry {
  promo: PromocionActiva
  totalQty: number
  primerProductoId: string
  productoIdsEnPedido: Set<string>
}

/**
 * Agrupa promos en "componentes conectados" (dos promos son vecinas si comparten
 * al menos un producto del pedido). Por cada componente deja sólo la ganadora:
 * mayor prioridad; en empate, id menor (creada antes) gana.
 */
function resolverConflictos(promosVistas: Map<string, PromoEntry>): PromoEntry[] {
  if (promosVistas.size === 0) return []

  const parent = new Map<string, string>()
  for (const id of promosVistas.keys()) parent.set(id, id)

  const find = (x: string): string => {
    let r = x
    while (parent.get(r)! !== r) r = parent.get(r)!
    let cur = x
    while (parent.get(cur)! !== r) {
      const next = parent.get(cur)!
      parent.set(cur, r)
      cur = next
    }
    return r
  }

  const union = (a: string, b: string) => {
    const ra = find(a), rb = find(b)
    if (ra !== rb) parent.set(ra, rb)
  }

  // Para cada producto del pedido, unir todas las promos que lo cubren
  const productoToPromos = new Map<string, string[]>()
  for (const [promoId, entry] of promosVistas) {
    for (const pid of entry.productoIdsEnPedido) {
      const arr = productoToPromos.get(pid) || []
      arr.push(promoId)
      productoToPromos.set(pid, arr)
    }
  }
  for (const promoIds of productoToPromos.values()) {
    for (let i = 1; i < promoIds.length; i++) union(promoIds[0], promoIds[i])
  }

  // Por componente elegir mejor (mayor prioridad, tiebreak id menor)
  const porComponente = new Map<string, PromoEntry[]>()
  for (const [promoId, entry] of promosVistas) {
    const root = find(promoId)
    const arr = porComponente.get(root) || []
    arr.push(entry)
    porComponente.set(root, arr)
  }

  const ganadores: PromoEntry[] = []
  for (const grupo of porComponente.values()) {
    grupo.sort((a, b) => {
      const pa = a.promo.prioridad ?? 0
      const pb = b.promo.prioridad ?? 0
      if (pa !== pb) return pb - pa
      const ia = Number(a.promo.id), ib = Number(b.promo.id)
      if (!Number.isNaN(ia) && !Number.isNaN(ib)) return ia - ib
      return a.promo.id.localeCompare(b.promo.id)
    })
    ganadores.push(grupo[0])
  }
  return ganadores
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

  const promosAcumuladas = new Map<string, PromoEntry>()

  for (const item of items) {
    const promos = promoMap.get(String(item.productoId))
    if (!promos) continue

    for (const promo of promos) {
      if (promo.tipo !== 'bonificacion') continue

      const existing = promosAcumuladas.get(promo.id)
      if (existing) {
        existing.totalQty += item.cantidad
        existing.productoIdsEnPedido.add(String(item.productoId))
      } else {
        promosAcumuladas.set(promo.id, {
          promo,
          totalQty: item.cantidad,
          primerProductoId: String(item.productoId),
          productoIdsEnPedido: new Set([String(item.productoId)]),
        })
      }
    }
  }

  // No nudgear promos que ya perdieron el conflicto por prioridad
  const ganadoras = resolverConflictos(promosAcumuladas)

  for (const { promo, totalQty, primerProductoId } of ganadoras) {
    const cantCompra = promo.reglas['cantidad_compra']
    const cantBonif = promo.reglas['cantidad_bonificacion']
    if (!cantCompra || !cantBonif) continue

    const resto = totalQty % cantCompra
    if (resto === 0) continue

    const faltante = cantCompra - resto
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

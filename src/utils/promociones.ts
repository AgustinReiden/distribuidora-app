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

export type ModoExclusion = 'acumulable' | 'excluyente'

export interface PromocionActiva {
  id: string
  nombre: string
  tipo: 'bonificacion'
  productoIds: string[]
  reglas: Record<string, number>
  productoRegaloId?: string
  prioridad?: number
  regaloMueveStock?: boolean
  modoExclusion?: ModoExclusion
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

  // 1. Recolectar promos vistas en el pedido
  const promosVistas = acumularPromos(items, promoMap, { skipOverride: true })

  for (const entry of promosVistas.values()) {
    for (const pid of entry.productoIdsEnPedido) productosConPromo.add(pid)
  }

  // 2. Filtrar solo las que DISPARAN (bloques >= 1) — clave para el fix del bug
  //    "2+2 con 2 fardos debe ganar sobre 3+1 con prio mayor si 3+1 no llega"
  const queDisparan: PromoEntry[] = []
  for (const entry of promosVistas.values()) {
    const { promo, totalQty } = entry
    const cantCompra = promo.reglas['cantidad_compra']
    const cantBonif = promo.reglas['cantidad_bonificacion']
    if (!cantCompra || !cantBonif || cantCompra <= 0) continue
    const bloques = Math.floor(totalQty / cantCompra)
    if (bloques <= 0) continue
    queDisparan.push(entry)
  }

  // 3. Separar acumulables (siempre pasan) vs excluyentes (se resuelven por grupo)
  const acumulables = queDisparan.filter(e => (e.promo.modoExclusion ?? 'acumulable') === 'acumulable')
  const excluyentes = queDisparan.filter(e => e.promo.modoExclusion === 'excluyente')

  // 4. Entre excluyentes: agrupar por productos compartidos y elegir ganador
  //    por tier más alto (mayor cantidad_compra), tiebreak prioridad, tiebreak id.
  const ganadoresExcluyentes = resolverConflictosExcluyentes(excluyentes)

  const finales = [...acumulables, ...ganadoresExcluyentes]

  for (const { promo, totalQty, primerProductoId } of finales) {
    const cantCompra = promo.reglas['cantidad_compra']
    const cantBonif = promo.reglas['cantidad_bonificacion']
    const bloques = Math.floor(totalQty / cantCompra)
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
// HELPERS DE EXCLUSIÓN
// =============================================================================

interface PromoEntry {
  promo: PromocionActiva
  totalQty: number
  primerProductoId: string
  productoIdsEnPedido: Set<string>
}

function acumularPromos(
  items: ItemPedido[],
  promoMap: PromoMap,
  opts: { skipOverride: boolean },
): Map<string, PromoEntry> {
  const promosVistas = new Map<string, PromoEntry>()

  for (const item of items) {
    if (opts.skipOverride && item.precioOverride) continue

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
    }
  }

  return promosVistas
}

/**
 * Union-find: dos promos son "vecinas" si comparten al menos 1 producto del pedido.
 * Por cada componente conectado, gana la de mayor cantidad_compra (tier más alto).
 * Desempates: mayor prioridad manual; luego id menor (promo creada antes).
 *
 * Importante: sólo opera sobre promos que YA disparan. Así, si "3+1 fardo" (tier
 * superior) no llega al umbral, la "2+2 botellas" de tier menor aplica igual.
 */
function resolverConflictosExcluyentes(excluyentes: PromoEntry[]): PromoEntry[] {
  if (excluyentes.length === 0) return []

  const byId = new Map<string, PromoEntry>()
  for (const e of excluyentes) byId.set(e.promo.id, e)

  const parent = new Map<string, string>()
  for (const id of byId.keys()) parent.set(id, id)

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

  // Indexar productos → promos (entre las excluyentes que disparan)
  const productoToPromos = new Map<string, string[]>()
  for (const [promoId, entry] of byId) {
    for (const pid of entry.productoIdsEnPedido) {
      const arr = productoToPromos.get(pid) || []
      arr.push(promoId)
      productoToPromos.set(pid, arr)
    }
  }
  for (const promoIds of productoToPromos.values()) {
    for (let i = 1; i < promoIds.length; i++) union(promoIds[0], promoIds[i])
  }

  // Agrupar por componente y elegir ganador: tier más alto, luego prioridad, luego id
  const porComponente = new Map<string, PromoEntry[]>()
  for (const [promoId, entry] of byId) {
    const root = find(promoId)
    const arr = porComponente.get(root) || []
    arr.push(entry)
    porComponente.set(root, arr)
  }

  const ganadores: PromoEntry[] = []
  for (const grupo of porComponente.values()) {
    grupo.sort((a, b) => {
      const ca = a.promo.reglas['cantidad_compra'] ?? 0
      const cb = b.promo.reglas['cantidad_compra'] ?? 0
      if (ca !== cb) return cb - ca // tier más alto gana (mayor cantidad_compra)
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

  // Mostramos nudges para promos que AÚN NO disparan. Para promos acumulables,
  // no hay conflicto. Para excluyentes, evitamos nudgear la que ya perdería el
  // conflicto con otra excluyente del mismo grupo que SÍ dispara y tiene mayor tier.
  const promosAcumuladas = acumularPromos(items, promoMap, { skipOverride: false })

  const ganadorasEnMismoGrupo = calcularGanadoresActualesPorGrupo(promosAcumuladas)

  for (const [promoId, { promo, totalQty, primerProductoId, productoIdsEnPedido }] of promosAcumuladas) {
    const cantCompra = promo.reglas['cantidad_compra']
    const cantBonif = promo.reglas['cantidad_bonificacion']
    if (!cantCompra || !cantBonif) continue

    const resto = totalQty % cantCompra
    if (resto === 0) continue

    // Si es excluyente y hay otra excluyente en el mismo grupo que ya dispara
    // y tiene tier superior, no nudgeamos (esta promo está bloqueada).
    if (promo.modoExclusion === 'excluyente') {
      const ganadora = findGanadoraEnGrupo(ganadorasEnMismoGrupo, productoIdsEnPedido)
      if (ganadora && ganadora.promo.id !== promoId) {
        const cantCompraGanadora = ganadora.promo.reglas['cantidad_compra'] ?? 0
        if (cantCompraGanadora > cantCompra) continue
      }
    }

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

/**
 * Para cada producto del pedido, indica cuál promo excluyente (de las que ya
 * disparan) es la ganadora actual. Se usa para suprimir nudges de excluyentes
 * perdedoras.
 */
function calcularGanadoresActualesPorGrupo(
  promosVistas: Map<string, PromoEntry>,
): Map<string, PromoEntry> {
  const disparan: PromoEntry[] = []
  for (const entry of promosVistas.values()) {
    const cantCompra = entry.promo.reglas['cantidad_compra']
    if (!cantCompra || cantCompra <= 0) continue
    if (Math.floor(entry.totalQty / cantCompra) <= 0) continue
    if (entry.promo.modoExclusion !== 'excluyente') continue
    disparan.push(entry)
  }
  const ganadoresPorProducto = new Map<string, PromoEntry>()
  const ganadores = resolverConflictosExcluyentes(disparan)
  for (const g of ganadores) {
    for (const pid of g.productoIdsEnPedido) {
      ganadoresPorProducto.set(pid, g)
    }
  }
  return ganadoresPorProducto
}

function findGanadoraEnGrupo(
  ganadoresPorProducto: Map<string, PromoEntry>,
  productoIds: Set<string>,
): PromoEntry | undefined {
  for (const pid of productoIds) {
    const g = ganadoresPorProducto.get(pid)
    if (g) return g
  }
  return undefined
}

/**
 * Utilidades para resolución de precios mayoristas por volumen
 *
 * Algoritmo:
 * 1. Para cada producto en el pedido, buscar sus grupos en el pricingMap
 * 2. Para cada grupo, sumar cantidades de TODOS los items del pedido que pertenecen al grupo
 * 3. Encontrar la escala más alta cuyo cantidad_minima <= total del grupo
 * 4. Si el producto pertenece a varios grupos, tomar el precio más bajo
 * 5. Nunca aumentar el precio (mayorista siempre <= regular)
 */

// =============================================================================
// TIPOS
// =============================================================================

/**
 * Configuracion por producto dentro de una escala combinada:
 *   - cantidad: cantidad minima individual que ese producto debe tener en el
 *     pedido para "contar" hacia la activacion de la escala.
 *   - precioOverride (opcional): precio mayorista especifico que usa ese
 *     producto cuando la escala aplica. Si es null/undefined, cae al
 *     precioUnitario de la escala.
 */
export interface ReglaProducto {
  cantidad: number
  precioOverride?: number | null
}

export interface EscalaPrecio {
  cantidadMinima: number
  /** Precio unitario base de la escala. Fallback para productos sin override. */
  precioUnitario: number
  etiqueta: string | null
  /**
   * Cantidad minima de productos DISTINTOS del grupo presentes en el pedido
   * (con cantidad >= su minimo individual, o > 0 si no tienen minimo) para
   * activar la escala. Default 1 = comportamiento clasico.
   */
  minProductosDistintos: number
  /**
   * Mapa productoId -> regla individual (cantidad minima + precio override).
   * Si un producto del grupo no esta en este mapa, basta con cantidad > 0
   * para contar y usa el precioUnitario de la escala. Ausencia total de
   * entradas = escala clasica.
   */
  minimosPorProducto: Map<string, ReglaProducto>
}

export interface GrupoPrecioInfo {
  grupoId: string
  grupoNombre: string
  escalas: EscalaPrecio[]
  productoIds: string[]
  moqPorProducto: Map<string, number>
}

/** Mapa de productoId → grupos a los que pertenece */
export type PricingMap = Map<string, GrupoPrecioInfo[]>

export interface PrecioResuelto {
  precioOriginal: number
  precioResuelto: number
  esMayorista: boolean
  grupoNombre: string | null
  etiqueta: string | null
  cantidadEnGrupo: number
  cantidadMinima: number | null
}

export interface FaltanteParaTier {
  grupoNombre: string
  faltante: number
  precioTier: number
  etiqueta: string | null
}

export interface ItemPedido {
  productoId: string
  cantidad: number
  precioUnitario: number
  precioOverride?: boolean
}

// =============================================================================
// FUNCIONES PRINCIPALES
// =============================================================================

/**
 * Indica si una escala es "combinada" (exige reglas mas alla del total del grupo).
 * Default (sin filas en minimosPorProducto y minProductosDistintos <= 1) = clasica.
 */
export function esEscalaCombinada(escala: EscalaPrecio): boolean {
  return escala.minProductosDistintos > 1 || escala.minimosPorProducto.size > 0
}

/**
 * Evalua si una escala aplica dadas las cantidades por producto del grupo en el pedido.
 *
 * Reglas:
 *   1. total del grupo >= escala.cantidadMinima.
 *   2. Si hay minimos por producto: ningun producto presente en el pedido con
 *      minimo configurado puede tener cantidad < minimo (si lo tiene, la escala
 *      falla incluso aunque ese producto no "cuente" individualmente).
 *   3. Cantidad de productos DISTINTOS del grupo que "cuentan" (presentes con
 *      cantidad >= su minimo individual, o >0 si no tienen minimo) debe ser
 *      >= escala.minProductosDistintos.
 */
export function escalaAplica(
  escala: EscalaPrecio,
  cantidadesPorProducto: Map<string, number>,
  productoIdsGrupo: string[]
): boolean {
  // 1. Total del grupo
  let totalGrupo = 0
  for (const pid of productoIdsGrupo) {
    totalGrupo += cantidadesPorProducto.get(pid) || 0
  }
  if (totalGrupo < escala.cantidadMinima) return false

  // 2. Si hay minimos por producto, validar que los presentes los cumplan
  if (escala.minimosPorProducto.size > 0) {
    for (const [pid, regla] of escala.minimosPorProducto) {
      const cantidad = cantidadesPorProducto.get(pid) || 0
      if (cantidad > 0 && cantidad < regla.cantidad) {
        return false
      }
    }
  }

  // 3. Contar productos distintos que cuentan
  const minK = Math.max(1, escala.minProductosDistintos)
  let productosQueCuentan = 0
  for (const pid of productoIdsGrupo) {
    const cantidad = cantidadesPorProducto.get(pid) || 0
    if (cantidad <= 0) continue
    const regla = escala.minimosPorProducto.get(pid)
    if (regla !== undefined) {
      if (cantidad >= regla.cantidad) productosQueCuentan++
    } else {
      // Sin minimo configurado: basta con estar presente
      productosQueCuentan++
    }
  }
  return productosQueCuentan >= minK
}

/**
 * Devuelve el precio efectivo que usa un producto cuando una escala aplica.
 * Respeta el override por producto si existe; si no, usa el precio de la escala.
 */
export function precioEfectivoEscala(escala: EscalaPrecio, productoId: string): number {
  const regla = escala.minimosPorProducto.get(String(productoId))
  if (regla && regla.precioOverride != null && regla.precioOverride > 0) {
    return regla.precioOverride
  }
  return escala.precioUnitario
}

/**
 * Resuelve los precios mayoristas para cada item del pedido
 *
 * @param items - Items del pedido actual
 * @param pricingMap - Mapa de productoId → grupos con escalas
 * @returns Mapa de productoId → precio resuelto
 */
export function resolverPreciosMayorista(
  items: ItemPedido[],
  pricingMap: PricingMap
): Map<string, PrecioResuelto> {
  const result = new Map<string, PrecioResuelto>()

  // Mapa productoId -> cantidad total en el pedido
  const cantidadesPorProducto = new Map<string, number>()
  for (const item of items) {
    const pid = String(item.productoId)
    cantidadesPorProducto.set(pid, (cantidadesPorProducto.get(pid) || 0) + item.cantidad)
  }

  // Pre-calcular total por grupo (compat con el campo cantidadEnGrupo del resultado)
  const totalPorGrupo = new Map<string, number>()
  const gruposVistos = new Set<string>()
  for (const item of items) {
    const grupos = pricingMap.get(String(item.productoId))
    if (!grupos) continue
    for (const grupo of grupos) {
      if (gruposVistos.has(grupo.grupoId)) continue
      gruposVistos.add(grupo.grupoId)
      let total = 0
      for (const pid of grupo.productoIds) {
        total += cantidadesPorProducto.get(String(pid)) || 0
      }
      totalPorGrupo.set(grupo.grupoId, total)
    }
  }

  // Resolver precio para cada item
  for (const item of items) {
    // Si el precio fue overrideado manualmente, respetar el precio manual
    if (item.precioOverride) {
      result.set(String(item.productoId), {
        precioOriginal: item.precioUnitario,
        precioResuelto: item.precioUnitario,
        esMayorista: false,
        grupoNombre: null,
        etiqueta: null,
        cantidadEnGrupo: item.cantidad,
        cantidadMinima: null
      })
      continue
    }

    const grupos = pricingMap.get(String(item.productoId))

    if (!grupos || grupos.length === 0) {
      result.set(String(item.productoId), {
        precioOriginal: item.precioUnitario,
        precioResuelto: item.precioUnitario,
        esMayorista: false,
        grupoNombre: null,
        etiqueta: null,
        cantidadEnGrupo: item.cantidad,
        cantidadMinima: null
      })
      continue
    }

    let mejorPrecio = item.precioUnitario
    let mejorGrupoNombre: string | null = null
    let mejorEtiqueta: string | null = null
    let mejorCantidadEnGrupo = item.cantidad
    let mejorCantidadMinima: number | null = null

    for (const grupo of grupos) {
      const productoIdsStr = grupo.productoIds.map(String)

      // Filtrar escalas que apliquen (clasica o combinada) y quedarme con la
      // de mayor cantidad_minima. En caso de empate por cantidad, gana la
      // de menor precio EFECTIVO para este producto en particular (respeta
      // overrides por producto). Asi una combinada con override mas bajo
      // gana a una clasica con el mismo umbral; y una clasica mas barata
      // gana si la combinada no bajo ese producto especifico.
      const pidStr = String(item.productoId)
      const escalasAplicables = grupo.escalas
        .filter(e => escalaAplica(e, cantidadesPorProducto, productoIdsStr))
        .sort((a, b) => {
          if (b.cantidadMinima !== a.cantidadMinima) {
            return b.cantidadMinima - a.cantidadMinima
          }
          return precioEfectivoEscala(a, pidStr) - precioEfectivoEscala(b, pidStr)
        })

      if (escalasAplicables.length === 0) continue

      const escalaElegida = escalasAplicables[0]
      const precioParaEsteProducto = precioEfectivoEscala(escalaElegida, pidStr)
      // Solo aplicar si el precio mayorista es menor o igual al actual mejor
      if (precioParaEsteProducto <= mejorPrecio) {
        mejorPrecio = precioParaEsteProducto
        mejorGrupoNombre = grupo.grupoNombre
        mejorEtiqueta = escalaElegida.etiqueta
        mejorCantidadEnGrupo = totalPorGrupo.get(grupo.grupoId) || 0
        mejorCantidadMinima = escalaElegida.cantidadMinima
      }
    }

    result.set(String(item.productoId), {
      precioOriginal: item.precioUnitario,
      precioResuelto: mejorPrecio,
      esMayorista: mejorPrecio < item.precioUnitario,
      grupoNombre: mejorGrupoNombre,
      etiqueta: mejorEtiqueta,
      cantidadEnGrupo: mejorCantidadEnGrupo,
      cantidadMinima: mejorCantidadMinima
    })
  }

  return result
}

/**
 * Calcula cuánto falta para alcanzar el próximo tier de precio
 *
 * @param items - Items del pedido actual
 * @param pricingMap - Mapa de pricing
 * @returns Array de nudges indicando faltantes para cada tier alcanzable
 */
export function calcularFaltanteParaTier(
  items: ItemPedido[],
  pricingMap: PricingMap
): FaltanteParaTier[] {
  const faltantes: FaltanteParaTier[] = []
  const gruposVistos = new Set<string>()

  // Calcular cantidades totales por grupo
  const cantidadesPorGrupo = new Map<string, number>()
  for (const item of items) {
    const grupos = pricingMap.get(String(item.productoId))
    if (!grupos) continue
    for (const grupo of grupos) {
      if (!cantidadesPorGrupo.has(grupo.grupoId)) {
        let totalGrupo = 0
        for (const otroItem of items) {
          if (grupo.productoIds.includes(String(otroItem.productoId))) {
            totalGrupo += otroItem.cantidad
          }
        }
        cantidadesPorGrupo.set(grupo.grupoId, totalGrupo)
      }
    }
  }

  for (const item of items) {
    const grupos = pricingMap.get(String(item.productoId))
    if (!grupos) continue

    for (const grupo of grupos) {
      if (gruposVistos.has(grupo.grupoId)) continue
      gruposVistos.add(grupo.grupoId)

      const totalGrupo = cantidadesPorGrupo.get(grupo.grupoId) || 0

      // Encontrar el proximo tier que no se ha alcanzado.
      // Las escalas combinadas no participan del nudge porque el mensaje
      // "te faltan X unidades" no puede expresar combinaciones requeridas.
      const escalasOrdenadas = grupo.escalas
        .filter(e => !esEscalaCombinada(e))
        .sort((a, b) => a.cantidadMinima - b.cantidadMinima)

      for (const escala of escalasOrdenadas) {
        if (escala.cantidadMinima > totalGrupo) {
          const faltante = escala.cantidadMinima - totalGrupo
          // Solo mostrar nudge si falta poco (menos del 50% del umbral)
          if (faltante <= Math.ceil(escala.cantidadMinima * 0.5)) {
            faltantes.push({
              grupoNombre: grupo.grupoNombre,
              faltante,
              precioTier: escala.precioUnitario,
              etiqueta: escala.etiqueta
            })
          }
          break // Solo el próximo tier
        }
      }
    }
  }

  return faltantes
}

/**
 * Aplica precios mayoristas a los items del pedido
 * Retorna nuevos items con precioUnitario actualizado
 */
export function aplicarPreciosMayorista(
  items: ItemPedido[],
  preciosResueltos: Map<string, PrecioResuelto>
): ItemPedido[] {
  return items.map(item => {
    if (item.precioOverride) return item
    const resuelto = preciosResueltos.get(String(item.productoId))
    if (resuelto && resuelto.esMayorista) {
      return { ...item, precioUnitario: resuelto.precioResuelto }
    }
    return item
  })
}

// =============================================================================
// CANTIDAD MÍNIMA DE PEDIDO (MOQ)
// =============================================================================

export interface ViolacionMOQ {
  productoId: string
  cantidadActual: number
  cantidadMinima: number
  grupoNombre: string
}

/**
 * Obtiene el MOQ efectivo de un producto.
 * Si pertenece a varios grupos, toma el más restrictivo (máximo).
 * Retorna 1 si no tiene MOQ configurado.
 */
export function obtenerMOQ(productoId: string, pricingMap: PricingMap): number {
  const grupos = pricingMap.get(String(productoId))
  if (!grupos) return 1
  let maxMoq = 1
  for (const grupo of grupos) {
    const moq = grupo.moqPorProducto.get(String(productoId))
    if (moq && moq > maxMoq) maxMoq = moq
  }
  return maxMoq
}

/**
 * Construye un mapa de productoId → MOQ efectivo para una lista de items.
 */
export function construirMOQMap(items: ItemPedido[], pricingMap: PricingMap): Map<string, number> {
  const map = new Map<string, number>()
  for (const item of items) {
    const moq = obtenerMOQ(item.productoId, pricingMap)
    if (moq > 1) {
      map.set(String(item.productoId), moq)
    }
  }
  return map
}

/**
 * Valida que todos los items cumplan con su cantidad mínima de pedido.
 * Retorna las violaciones encontradas.
 */
export function validarMOQPedido(items: ItemPedido[], pricingMap: PricingMap): ViolacionMOQ[] {
  const violaciones: ViolacionMOQ[] = []
  for (const item of items) {
    const grupos = pricingMap.get(String(item.productoId))
    if (!grupos) continue
    for (const grupo of grupos) {
      const moq = grupo.moqPorProducto.get(String(item.productoId))
      if (moq && item.cantidad < moq) {
        violaciones.push({
          productoId: String(item.productoId),
          cantidadActual: item.cantidad,
          cantidadMinima: moq,
          grupoNombre: grupo.grupoNombre,
        })
        break // Una violación por producto es suficiente
      }
    }
  }
  return violaciones
}

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

export interface EscalaPrecio {
  cantidadMinima: number
  precioUnitario: number
  etiqueta: string | null
}

export interface GrupoPrecioInfo {
  grupoId: string
  grupoNombre: string
  escalas: EscalaPrecio[]
  productoIds: string[]
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
}

// =============================================================================
// FUNCIONES PRINCIPALES
// =============================================================================

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

  // Pre-calcular cantidades totales por grupo
  const cantidadesPorGrupo = new Map<string, number>()
  for (const item of items) {
    const grupos = pricingMap.get(String(item.productoId))
    if (!grupos) continue
    for (const grupo of grupos) {
      const totalActual = cantidadesPorGrupo.get(grupo.grupoId) || 0
      // Sumar las cantidades de TODOS los items del pedido que pertenecen a este grupo
      let totalGrupo = 0
      for (const otroItem of items) {
        if (grupo.productoIds.includes(String(otroItem.productoId))) {
          totalGrupo += otroItem.cantidad
        }
      }
      // Usar el máximo calculado (evitar doble conteo)
      if (totalGrupo > totalActual) {
        cantidadesPorGrupo.set(grupo.grupoId, totalGrupo)
      }
    }
  }

  // Resolver precio para cada item
  for (const item of items) {
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
      const totalGrupo = cantidadesPorGrupo.get(grupo.grupoId) || 0

      // Encontrar la escala más alta aplicable (ordenar por cantidad_minima descendente)
      const escalasOrdenadas = [...grupo.escalas]
        .filter(e => e.cantidadMinima <= totalGrupo)
        .sort((a, b) => b.cantidadMinima - a.cantidadMinima)

      if (escalasOrdenadas.length > 0) {
        const escalaAplicable = escalasOrdenadas[0]
        // Solo aplicar si el precio mayorista es menor o igual al original
        if (escalaAplicable.precioUnitario <= mejorPrecio) {
          mejorPrecio = escalaAplicable.precioUnitario
          mejorGrupoNombre = grupo.grupoNombre
          mejorEtiqueta = escalaAplicable.etiqueta
          mejorCantidadEnGrupo = totalGrupo
          mejorCantidadMinima = escalaAplicable.cantidadMinima
        }
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

      // Encontrar el próximo tier que no se ha alcanzado
      const escalasOrdenadas = [...grupo.escalas]
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
    const resuelto = preciosResueltos.get(String(item.productoId))
    if (resuelto && resuelto.esMayorista) {
      return { ...item, precioUnitario: resuelto.precioResuelto }
    }
    return item
  })
}

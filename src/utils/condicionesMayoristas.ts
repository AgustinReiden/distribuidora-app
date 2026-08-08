/**
 * Vista "por producto" de las condiciones mayoristas.
 *
 * Los grupos de precio están modelados al revés de como los mira el usuario en
 * la ficha: un grupo tiene N productos y M escalas, y el dueño quiere ver, para
 * UN producto, a qué precio termina vendiéndose en cada escala y con qué margen.
 * Esto invierte esa relación sin tocar el modelo.
 *
 * Punto fino: cuando la escala es combinada y tiene un `precio_unitario_override`
 * para este producto, el precio que realmente aplica es el override, no el de la
 * escala. La UI necesita saber cuál de los dos está mostrando, porque editar uno
 * afecta solo a este producto y editar el otro afecta a todo el grupo.
 */
import type { GrupoPrecioConDetalles } from '../types'
import type { EscalaPrecio } from './precioMayorista'

export interface EscalaDeProducto {
  escalaId: string
  cantidadMinima: number
  /** Precio base de la escala: el que aplica a todo el grupo. */
  precioGrupo: number
  /** Precio propio de este producto en esta escala, si lo tiene. */
  precioOverride: number | null
  /** El que realmente se cobra: override si existe, si no el del grupo. */
  precioEfectivo: number
  /** true si `precioEfectivo` viene del override (editarlo NO afecta al resto). */
  esOverride: boolean
  activo: boolean
  /** Para `describirReglaEscala` — la regla completa, no solo la parte del producto. */
  escala: EscalaPrecio
}

export interface CondicionMayoristaProducto {
  grupoId: string
  grupoNombre: string
  descripcion: string | null
  activo: boolean
  /** Cuántos productos comparten esta condición (incluye al actual). */
  cantidadProductos: number
  escalas: EscalaDeProducto[]
}

function minimosDeEscala(
  grupo: GrupoPrecioConDetalles,
  escalaId: string,
): Map<string, { cantidad: number; precioOverride?: number | null }> {
  const map = new Map<string, { cantidad: number; precioOverride?: number | null }>()
  for (const m of grupo.escalaMinimos?.[String(escalaId)] || []) {
    map.set(String(m.producto_id), {
      cantidad: Number(m.cantidad_minima_por_item),
      precioOverride: m.precio_unitario_override != null ? Number(m.precio_unitario_override) : null,
    })
  }
  return map
}

/**
 * Condiciones mayoristas que incluyen a `productoId`, ordenadas por nombre de
 * grupo y, dentro de cada uno, por cantidad mínima ascendente.
 *
 * Incluye los grupos y escalas inactivos, marcados: esconderlos haría que una
 * condición desactivada parezca inexistente y el dueño la vuelva a crear.
 */
export function condicionesDeProducto(
  grupos: GrupoPrecioConDetalles[],
  productoId: string,
): CondicionMayoristaProducto[] {
  const pid = String(productoId)
  const salida: CondicionMayoristaProducto[] = []

  for (const grupo of grupos) {
    if (!grupo.productos.some(p => String(p.producto_id) === pid)) continue

    const escalas: EscalaDeProducto[] = grupo.escalas
      .slice()
      .sort((a, b) => a.cantidad_minima - b.cantidad_minima)
      .map((e): EscalaDeProducto => {
        const minimos = minimosDeEscala(grupo, String(e.id))
        const propio = minimos.get(pid)
        const override = propio?.precioOverride != null && propio.precioOverride > 0
          ? Number(propio.precioOverride)
          : null
        const precioGrupo = Number(e.precio_unitario)
        return {
          escalaId: String(e.id),
          cantidadMinima: e.cantidad_minima,
          precioGrupo,
          precioOverride: override,
          precioEfectivo: override ?? precioGrupo,
          esOverride: override != null,
          activo: e.activo !== false,
          escala: {
            cantidadMinima: e.cantidad_minima,
            precioUnitario: precioGrupo,
            etiqueta: e.etiqueta || null,
            minProductosDistintos: e.min_productos_distintos ?? 1,
            minimosPorProducto: minimos,
          },
        }
      })

    salida.push({
      grupoId: String(grupo.id),
      grupoNombre: grupo.nombre,
      descripcion: grupo.descripcion ?? null,
      activo: grupo.activo !== false,
      cantidadProductos: grupo.productos.length,
      escalas,
    })
  }

  return salida.sort((a, b) => a.grupoNombre.localeCompare(b.grupoNombre))
}

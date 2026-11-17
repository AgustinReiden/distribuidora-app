/**
 * Qué combos vigentes se resienten si se desactiva un producto (#1596, 1596-b11).
 *
 * Desactivar un producto ya avisaba de las promos de regalo (`promosAfectadasPorDesactivar`)
 * pero no de los combos: un producto inactivo no se vende, así que el combo pierde ese
 * producto en su lugar. Si era la única opción de un lugar, el combo deja de poder armarse.
 */
import { resolverLugares, type LugarCombo, type ProductoCatalogo } from './comboCategorias'

export interface ComboParaAviso {
  nombre: string
  activo: boolean
  fechaFin?: string | null
  componentes: readonly LugarCombo[]
  productoAMoverId?: string | null
}

export interface CombosAfectados {
  /** Combos que se quedan sin ninguna opción en alguno de sus lugares (o sin el producto que mueven). */
  sinAlternativa: string[]
  /** Combos que pierden este producto pero siguen teniendo otro en ese lugar. */
  conAlternativa: string[]
}

export function combosAfectadosPorDesactivar(
  productoId: string | number,
  combos: readonly ComboParaAviso[],
  catalogo: readonly ProductoCatalogo[],
  hoy?: string,
): CombosAfectados {
  const id = String(productoId)
  const resultado: CombosAfectados = { sinAlternativa: [], conAlternativa: [] }
  const activos = new Set(catalogo.filter(p => p.activo !== false).map(p => String(p.id)))

  for (const combo of combos) {
    if (!combo.activo) continue
    if (hoy && combo.fechaFin && combo.fechaFin < hoy) continue

    const lugares = resolverLugares(combo.componentes, catalogo)
    // Los sueltos pueden estar ya inactivos: no cuentan como alternativa.
    const conElProducto = lugares.filter(l => l.productos.includes(id))
    const seRompe = conElProducto.some(l => l.productos.every(p => p === id || !activos.has(p)))
      || (combo.productoAMoverId != null && String(combo.productoAMoverId) === id)

    if (seRompe) resultado.sinAlternativa.push(combo.nombre)
    else if (conElProducto.length > 0) resultado.conAlternativa.push(combo.nombre)
  }
  return resultado
}

function listar(nombres: string[]): string {
  const q = nombres.map(n => `«${n}»`)
  if (q.length === 1) return q[0]
  return `${q.slice(0, -1).join(', ')} y ${q[q.length - 1]}`
}

/** Texto de advertencia para el confirm; '' si ningún combo se ve afectado. */
export function avisoCombosDesactivarProducto(afectados: CombosAfectados): string {
  const lineas: string[] = []
  const { sinAlternativa, conAlternativa } = afectados
  if (sinAlternativa.length > 0) {
    lineas.push(
      `Es parte del combo ${listar(sinAlternativa)} y no tiene otro producto que lo reemplace: ` +
        `${sinAlternativa.length > 1 ? 'esos combos dejan' : 'ese combo deja'} de poder armarse.`,
    )
  }
  if (conAlternativa.length > 0) {
    lineas.push(
      `También es una de las opciones del combo ${listar(conAlternativa)}: ` +
        `${conAlternativa.length > 1 ? 'siguen' : 'sigue'} armándose con los otros productos de ese lugar.`,
    )
  }
  return lineas.join('\n')
}

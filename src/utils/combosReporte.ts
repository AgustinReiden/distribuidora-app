/**
 * Cuentas de la sección "Combos" del reporte gerencial (#1193).
 *
 * Los números gordos los agrega la base (`reporte_combos`, mig 387); acá sólo
 * quedan cortes de presentación: la serie por período, para un combo o para
 * todos, y los porcentajes.
 *
 * El descuento del combo es INFORMATIVO. La venta ya entró más barata, así que
 * restarlo en la cascada o en el margen neto lo contaría dos veces: nada de
 * este archivo lo resta de un margen.
 */
import type { ComboPeriodoReporte, ReporteCombos } from '../hooks/queries/useReporteGerencialQuery'

export interface PuntoSerieCombos {
  periodo: string
  combos: number
  venta: number
  descuento: number
  margen: number
}

const num = (v: unknown): number => {
  const x = Number(v)
  return Number.isFinite(x) ? x : 0
}

/** Suma las filas (mes|semana × combo) por período; con `comboId`, sólo ese combo. */
export function serieDeCombos(
  filas: readonly (ComboPeriodoReporte & { mes?: string; semana?: string })[],
  comboId: number | null,
): PuntoSerieCombos[] {
  const porPeriodo = new Map<string, PuntoSerieCombos>()
  for (const f of filas) {
    if (comboId != null && Number(f.combo_id) !== comboId) continue
    const periodo = f.mes ?? f.semana ?? ''
    const p = porPeriodo.get(periodo) ?? { periodo, combos: 0, venta: 0, descuento: 0, margen: 0 }
    p.combos += num(f.combos)
    p.venta += num(f.venta)
    p.descuento += num(f.descuento)
    p.margen += num(f.margen)
    porPeriodo.set(periodo, p)
  }
  return [...porPeriodo.values()].sort((a, b) => a.periodo.localeCompare(b.periodo))
}

/** Descuento por mes ('YYYY-MM'): la columna "Desc. combos" de la evolución mensual. */
export function descuentoPorMes(combos: ReporteCombos | undefined): Map<string, number> {
  const m = new Map<string, number>()
  for (const p of serieDeCombos(combos?.mensual ?? [], null)) m.set(p.periodo, p.descuento)
  return m
}

/** Ratio (0..1) o 0 si el denominador no es positivo. */
export function ratio(parte: number, total: number): number {
  return total > 0 ? parte / total : 0
}

/**
 * Variación de la rotación de un componente: unidades por semana durante el
 * combo contra el período igual de antes. `null` si antes no vendía nada: no
 * hay contra qué comparar, y un "+∞%" no le sirve a nadie.
 */
export function variacionRotacion(durante: number, antes: number): number | null {
  const a = num(antes)
  if (a <= 0) return null
  return (num(durante) - a) / a
}

/** Conversión para "subir el ticket": pedidos con el combo / pedidos con alguno de sus productos. */
export function conversionCombo(conCombo: number, conProducto: number): number {
  return ratio(num(conCombo), num(conProducto))
}

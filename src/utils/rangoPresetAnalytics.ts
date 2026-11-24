import { fechaLocalISO } from './formatters'

export type PresetAnalyticsId = 'ultimo_mes' | 'ultimos_3_meses' | 'este_ano' | 'personalizado'

/**
 * El rango [desde, hasta] de los atajos de «Centro de análisis» (infra-INF-2, tanda 6 de #1603).
 *
 * Se arma con el día ARGENTINO de `ahora`, sin pasar por los campos del Date local: con
 * `new Date(now.getFullYear(), now.getMonth() - 1, now.getDate())` el «desde» salía de la
 * medianoche del dispositivo y se formateaba en huso Argentina, así que un dispositivo en UTC (o
 * al este) lo dejaba un día antes, y a la noche argentina usaba el día equivocado como base.
 */
export function rangoPresetAnalytics(preset: PresetAnalyticsId, ahora: Date = new Date()): { desde: string; hasta: string } {
  const hasta = fechaLocalISO(ahora)
  const [y, m, d] = hasta.split('-').map(Number)
  switch (preset) {
    case 'ultimos_3_meses':
      return { desde: desdeMesesAtras(y, m, d, 3), hasta }
    case 'este_ano':
      return { desde: `${y}-01-01`, hasta }
    case 'ultimo_mes':
    default:
      return { desde: desdeMesesAtras(y, m, d, 1), hasta }
  }
}

/** Mismo día N meses antes (31 de marzo - 1 mes = 3 de marzo: el rollover de siempre de Date). */
function desdeMesesAtras(y: number, m: number, d: number, meses: number): string {
  return new Date(Date.UTC(y, m - 1 - meses, d)).toISOString().slice(0, 10)
}

/**
 * Atajos de período para el reporte de ventas por cliente/zona.
 *
 * Se calculan contra la fecha de hoy en hora local, no hardcodeados: el mes en
 * curso y los dos anteriores, más el acumulado del año.
 *
 * La aritmética pura (fin de mes, restar N meses, formatear YYYY-MM-DD en
 * componentes locales) vive en fechaLocal.ts, compartida con
 * ReportesGerencialesContainer.tsx.
 */
import { ymdLocal, ultimoDiaDelMes, primerDiaMesAtras } from './fechaLocal'

export { ultimoDiaDelMes }

export interface PeriodoPreset {
  /** Estable, sirve de key de React y de valor del <select>. */
  id: string
  /** "Julio 2026", "Agosto 2026 (en curso)", "Año 2026". */
  label: string
  /** 'YYYY-MM-DD' */
  desde: string
  /** 'YYYY-MM-DD' */
  hasta: string
}

const MESES = [
  'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
  'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre',
]

/**
 * Preset del mes calendario que está `atras` meses antes del de `hoy`
 * (0 = mes en curso). El mes en curso corta en el día de hoy, no a fin de mes:
 * pedir hasta el 31 cuando estamos a 20 no cambia el número pero hace creer que
 * el período está cerrado.
 */
export function presetMes(atras: number, hoy: Date = new Date()): PeriodoPreset {
  const ref = primerDiaMesAtras(hoy, atras)
  const anio = ref.getFullYear()
  const mes0 = ref.getMonth()
  const enCurso = atras === 0

  return {
    id: `mes-${anio}-${String(mes0 + 1).padStart(2, '0')}`,
    label: `${MESES[mes0]} ${anio}${enCurso ? ' (en curso)' : ''}`,
    desde: ymdLocal(anio, mes0, 1),
    hasta: enCurso ? ymdLocal(anio, mes0, hoy.getDate()) : ymdLocal(anio, mes0, ultimoDiaDelMes(anio, mes0)),
  }
}

/** Del 1 de enero al día de hoy. */
export function presetAnio(hoy: Date = new Date()): PeriodoPreset {
  const anio = hoy.getFullYear()
  return {
    id: `anio-${anio}`,
    label: `Año ${anio}`,
    desde: ymdLocal(anio, 0, 1),
    hasta: ymdLocal(anio, hoy.getMonth(), hoy.getDate()),
  }
}

/**
 * Los atajos que se ofrecen en el reporte: el año en curso y los últimos tres
 * meses calendario (el actual y los dos cerrados anteriores).
 */
export function presetsVentas(hoy: Date = new Date()): PeriodoPreset[] {
  return [presetAnio(hoy), presetMes(0, hoy), presetMes(1, hoy), presetMes(2, hoy)]
}

/** Etiqueta legible de una clave 'YYYY-MM' que devuelve el RPC. */
export function labelMes(clave: string): string {
  const [a, m] = clave.split('-')
  const mes0 = Number(m) - 1
  if (!MESES[mes0]) return clave
  return `${MESES[mes0].slice(0, 3)} ${a.slice(2)}`
}

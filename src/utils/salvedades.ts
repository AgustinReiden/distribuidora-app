/**
 * Cálculo de las estadísticas (KPIs) de salvedades. Función pura para que el
 * caller decida sobre qué lista corre: la vista de Salvedades tiene que
 * pasarle la lista ya filtrada (motivo, estado, fecha), no todo el universo
 * cargado — si no, las tarjetas muestran un número que no corresponde a lo
 * que se está mirando en pantalla.
 */
import type { SalvedadItemDBExtended, EstadisticasSalvedades } from '../types'

/** Lo único que miran los KPIs: la consulta agregada de la vista trae sólo esto. */
export type FilaEstadisticaSalvedad = Pick<SalvedadItemDBExtended, 'estado_resolucion' | 'monto_afectado'>

export function calcularEstadisticasSalvedades(
  salvedades: FilaEstadisticaSalvedad[],
): EstadisticasSalvedades {
  return {
    total: salvedades.length,
    pendientes: salvedades.filter(s => s.estado_resolucion === 'pendiente').length,
    resueltas: salvedades.filter(s => s.estado_resolucion !== 'pendiente' && s.estado_resolucion !== 'anulada').length,
    anuladas: salvedades.filter(s => s.estado_resolucion === 'anulada').length,
    monto_total_afectado: salvedades.reduce((sum, s) => sum + (s.monto_afectado || 0), 0),
    monto_pendiente: salvedades
      .filter(s => s.estado_resolucion === 'pendiente')
      .reduce((sum, s) => sum + (s.monto_afectado || 0), 0),
  }
}

type ConEstado = { estado_resolucion?: string | null }

/** Una salvedad anulada deshace todo: las unidades vuelven al pedido (#1180). */
export function esSalvedadAnulada(s: ConEstado): boolean {
  return s.estado_resolucion === 'anulada'
}

/** Las que siguen valiendo: todas menos las anuladas. Conserva el orden. */
export function salvedadesVigentes<T extends ConEstado>(lista: readonly T[] | undefined | null): T[] {
  return (lista ?? []).filter(s => !esSalvedadAnulada(s))
}

/**
 * Lo que el total del pedido subió por los combos que rompió el cliente (#1192),
 * sumando el recargo de las salvedades que le pasen (las vigentes). Va aparte de
 * `monto_afectado`; puede ser negativo si algo volvió a un combo. En centavos.
 */
export function totalRecargoCombos(lista: readonly { recargo_combo?: number | null }[] | undefined | null): number {
  return Math.round((lista ?? []).reduce((suma, s) => suma + (Number(s.recargo_combo) || 0), 0) * 100) / 100
}

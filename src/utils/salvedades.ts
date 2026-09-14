/**
 * Cálculo de las estadísticas (KPIs) de salvedades. Función pura para que el
 * caller decida sobre qué lista corre: la vista de Salvedades tiene que
 * pasarle la lista ya filtrada (motivo, estado, fecha), no todo el universo
 * cargado — si no, las tarjetas muestran un número que no corresponde a lo
 * que se está mirando en pantalla.
 */
import type { SalvedadItemDBExtended, EstadisticasSalvedades } from '../types'

export function calcularEstadisticasSalvedades(
  salvedades: SalvedadItemDBExtended[],
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

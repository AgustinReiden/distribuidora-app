/**
 * Exportación a Excel de los gastos de un mes.
 *
 * Una fila por gasto que toca el mes. "Cuota del mes" es lo que el gasto aporta
 * al resultado de ese mes (`cuotaDelMes`); "Total" es el monto del comprobante.
 */
import { createAndDownloadExcel } from './excel'
import { cuotaDelMes, etiquetaComprobante, etiquetaGrupo, etiquetaMes } from './gastos'
import { nombreDeTransportista } from './rendicionGastos'
import type { Gasto } from '../types/gastos'

export interface OpcionesExportGastos {
  /** Para poner el nombre de la sucursal y no su id. */
  sucursales?: Array<{ id: number; nombre: string }>
  /** Para poner el nombre de la rendición de la que salió la plata. */
  transportistas?: Array<{ id: string; nombre: string }>
  /** Para poner el nombre del empleado que pagó con su plata. */
  empleados?: Array<{ id: number; nombre: string }>
}

const diaArgentino = (fechaISO: string): string => {
  const [a, m, d] = fechaISO.slice(0, 10).split('-')
  return `${d}/${m}/${a}`
}

function conQuePlata(
  g: Gasto,
  transportistas: Array<{ id: string; nombre: string }>,
  empleados: Array<{ id: number; nombre: string }>,
): string {
  if (g.origen_pago === 'rendicion' && g.rendicion_fecha) {
    return `Rendición de ${nombreDeTransportista(g.rendicion_transportista_id, transportistas)} del ${diaArgentino(g.rendicion_fecha)}`
  }
  if (g.origen_pago === 'empleado') {
    const nombre = empleados.find(e => e.id === g.empleado_id)?.nombre
    return nombre ? `Un empleado: ${nombre}` : 'Un empleado'
  }
  return 'La oficina'
}

export function armarFilasGastos(
  gastos: Gasto[],
  mes: string,
  { sucursales = [], transportistas = [], empleados = [] }: OpcionesExportGastos = {},
): Record<string, unknown>[] {
  return gastos.flatMap(g => {
    const cuota = cuotaDelMes(g, mes)
    if (!cuota) return []
    const sucursal = g.compartido
      ? 'Compartido'
      : sucursales.find(s => s.id === g.sucursal_id)?.nombre ?? String(g.sucursal_id)
    return [{
      'Fecha': diaArgentino(g.fecha),
      'Rubro': g.rubro?.nombre ?? '',
      'Grupo': g.rubro ? etiquetaGrupo(g.rubro.grupo) : '',
      'Comprobante': etiquetaComprobante(g.comprobante),
      'Número': g.comprobante_numero ?? '',
      'Sucursal': sucursal,
      'Con qué plata': conQuePlata(g, transportistas, empleados),
      'Vehículo': g.vehiculo?.patente ?? '',
      'Total': g.monto_total,
      'Cuota del mes': cuota.monto,
      'Cuota': cuota.n > 1 ? `${cuota.k} de ${cuota.n}` : '',
      'Observación': g.observacion ?? '',
    }]
  })
}

export async function exportarGastosDelMes(
  gastos: Gasto[],
  mes: string,
  opciones: OpcionesExportGastos = {},
): Promise<void> {
  const filas = armarFilasGastos(gastos, mes, opciones)
  await createAndDownloadExcel(filas, `gastos-${mes.slice(0, 7)}`, etiquetaMes(mes))
}

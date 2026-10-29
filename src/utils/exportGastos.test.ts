import { describe, it, expect, vi, beforeEach } from 'vitest'

const descargar = vi.fn()
vi.mock('./excel', () => ({ createAndDownloadExcel: (...args: unknown[]) => descargar(...args) }))

import { armarFilasGastos, exportarGastosDelMes } from './exportGastos'
import type { Gasto } from '../types/gastos'

const base: Gasto = {
  id: 1, sucursal_id: 1, compartido: false, fecha: '2026-10-15', rubro_id: 3, monto_total: 8500,
  comprobante: 'ticket', comprobante_numero: null, alicuota_iva: null, iva: 0, percepcion_iva: 0,
  percepcion_iibb: 0, otros_impuestos: 0, neto: 8500, costo: 8500, vehiculo_id: null, litros: null,
  mes_imputado: '2026-10-01', repartir_meses: 1, mes_fin: '2026-10-01', origen_pago: 'oficina',
  rendicion_transportista_id: null, rendicion_fecha: null, observacion: null, creado_por: 'u-1', anulado_at: null, created_at: '2026-10-15T10:00:00Z',
  rubro: { id: 3, nombre: 'Librería', grupo: 'administracion' }, vehiculo: null,
}

const SUCURSALES = [{ id: 1, nombre: 'Tucumán' }, { id: 2, nombre: 'Taco Pozo' }]

beforeEach(() => descargar.mockReset())

describe('armarFilasGastos', () => {
  it('una fila por gasto, con las columnas del plan en orden', () => {
    const [fila] = armarFilasGastos([base], '2026-10-01', { sucursales: SUCURSALES })

    expect(Object.keys(fila)).toEqual([
      'Fecha', 'Rubro', 'Grupo', 'Comprobante', 'Número', 'Sucursal', 'Vehículo',
      'Total', 'Cuota del mes', 'Cuota', 'Observación',
    ])
    expect(fila).toMatchObject({
      'Fecha': '15/10/2026', 'Rubro': 'Librería', 'Grupo': 'Administración', 'Comprobante': 'Ticket',
      'Sucursal': 'Tucumán', 'Total': 8500, 'Cuota del mes': 8500, 'Cuota': '',
    })
  })

  it('un gasto repartido exporta la cuota del mes y "k de n"', () => {
    const seguro: Gasto = {
      ...base, id: 2, monto_total: 1320000, costo: 1320000, comprobante: 'recibo', repartir_meses: 12,
      mes_fin: '2027-09-01', rubro: { id: 2, nombre: 'Seguro', grupo: 'vehiculos' },
      vehiculo: { id: 7, patente: 'AC456EF', descripcion: 'Partner' },
    }
    const [fila] = armarFilasGastos([seguro], '2026-12-01')

    expect(fila).toMatchObject({ 'Total': 1320000, 'Cuota del mes': 110000, 'Cuota': '3 de 12', 'Vehículo': 'AC456EF' })
  })

  it('el compartido dice Compartido y un gasto fuera de ventana no sale', () => {
    const compartido = { ...base, id: 3, compartido: true }
    const fueraDeMes = { ...base, id: 4, mes_imputado: '2026-08-01', mes_fin: '2026-08-01' }
    const filas = armarFilasGastos([compartido, fueraDeMes], '2026-10-01', { sucursales: SUCURSALES })

    expect(filas).toHaveLength(1)
    expect(filas[0]['Sucursal']).toBe('Compartido')
  })
})

describe('exportarGastosDelMes', () => {
  it('descarga el Excel con el mes en el nombre', async () => {
    await exportarGastosDelMes([base], '2026-10-01', { sucursales: SUCURSALES })

    expect(descargar).toHaveBeenCalledTimes(1)
    const [filas, nombre, hoja] = descargar.mock.calls[0]
    expect(filas).toHaveLength(1)
    expect(nombre).toBe('gastos-2026-10')
    expect(hoja).toBe('octubre 2026')
  })
})

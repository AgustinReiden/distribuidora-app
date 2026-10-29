import { describe, it, expect } from 'vitest'
import {
  claveRendicion,
  efectivoAEntregar,
  payloadDeGasto,
  itemsDelCierre,
  totalDelCierre,
  cambiosDelCierre,
  type ItemCierre,
} from './rendicionGastos'
import type { GastoDeRendicion } from '../types/gastos'

const combustible: GastoDeRendicion = {
  id: 7, sucursal_id: 1, compartido: false, fecha: '2026-10-28', rubro_id: 1,
  monto_total: 50000, comprobante: 'factura_a', comprobante_numero: '0005-00012345',
  alicuota_iva: 21, iva: 8677.69, percepcion_iva: 0, percepcion_iibb: 0, otros_impuestos: 0,
  neto: 41322.31, costo: 41322.31, vehiculo_id: 3, litros: 38.5, mes_imputado: '2026-10-01',
  repartir_meses: 1, mes_fin: '2026-10-01', origen_pago: 'rendicion',
  rendicion_transportista_id: 'tr-1', rendicion_fecha: '2026-10-28',
  observacion: null, creado_por: 'u-1', anulado_at: null, created_at: '2026-10-28T10:00:00Z',
  rubro: { id: 1, nombre: 'Combustible', grupo: 'vehiculos' },
  vehiculo: { id: 3, patente: 'AC456EF', descripcion: 'Partner' },
  km_tablero: 184230,
}

const otro = (id: number, monto: number): GastoDeRendicion => ({ ...combustible, id, monto_total: monto })

describe('claveRendicion', () => {
  it('une transportista y día', () => {
    expect(claveRendicion('tr-1', '2026-10-28')).toBe('tr-1|2026-10-28')
  })
})

describe('efectivoAEntregar', () => {
  it('resta los gastos del efectivo cobrado', () => {
    expect(efectivoAEntregar(1245300, 50000)).toBe(1195300)
  })
  it('da negativo si los gastos superan el efectivo', () => {
    expect(efectivoAEntregar(0, 50000)).toBe(-50000)
  })
  it('redondea a dos decimales', () => {
    expect(efectivoAEntregar(100.1, 0.2)).toBe(99.9)
  })
})

describe('payloadDeGasto', () => {
  it('lleva todas las claves del payload, con id y km', () => {
    expect(payloadDeGasto(combustible)).toEqual({
      id: 7, fecha: '2026-10-28', rubro_id: 1, monto_total: 50000, comprobante: 'factura_a',
      comprobante_numero: '0005-00012345', alicuota_iva: 21, iva: 8677.69, percepcion_iva: 0,
      percepcion_iibb: 0, otros_impuestos: 0, sucursal_id: 1, compartido: false, vehiculo_id: 3,
      litros: 38.5, km_tablero: 184230, mes_imputado: '2026-10-01', repartir_meses: 1,
      origen_pago: 'rendicion', rendicion_transportista_id: 'tr-1', rendicion_fecha: '2026-10-28',
      observacion: null,
    })
  })
  it('sin km_tablero lo deja en null', () => {
    const { km_tablero: _km, ...sinKm } = combustible
    expect(payloadDeGasto(sinKm).km_tablero).toBeNull()
  })
  it('un origen distinto de rendición da oficina', () => {
    expect(payloadDeGasto({ ...combustible, origen_pago: 'empleado' }).origen_pago).toBe('oficina')
  })
})

describe('itemsDelCierre', () => {
  it('un ítem por gasto, sin editar ni quitar', () => {
    const items = itemsDelCierre([combustible, otro(8, 100)])
    expect(items.map(i => i.clave)).toEqual(['g7', 'g8'])
    expect(items[0]).toMatchObject({ original: combustible, editado: false, quitado: false })
    expect(items[0].payload).toEqual(payloadDeGasto(combustible))
  })
})

describe('totalDelCierre', () => {
  it('suma los no quitados', () => {
    const items = itemsDelCierre([otro(7, 50000), otro(8, 12000), otro(9, 8500)])
    items[1].quitado = true
    expect(totalDelCierre(items)).toEqual({ cantidad: 2, total: 58500 })
  })
})

describe('cambiosDelCierre', () => {
  it('manda sólo lo nuevo, lo editado y lo quitado', () => {
    const items: ItemCierre[] = itemsDelCierre([otro(7, 1000), otro(8, 2000), otro(9, 3000)])
    items[1] = { ...items[1], editado: true, payload: { ...items[1].payload, monto_total: 2500 } }
    items[2] = { ...items[2], quitado: true }
    const nuevo = { ...payloadDeGasto(otro(0, 700)), id: undefined }
    const nuevoQuitado = { ...nuevo, monto_total: 1 }
    items.push(
      { clave: 'n1', original: null, payload: nuevo, editado: false, quitado: false },
      { clave: 'n2', original: null, payload: nuevoQuitado, editado: false, quitado: true },
    )
    expect(cambiosDelCierre(items, [7, 8, 9])).toEqual({
      vistos: [7, 8, 9],
      guardar: [items[1].payload, nuevo],
      quitar: [9],
    })
  })
})

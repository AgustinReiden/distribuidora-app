import { describe, it, expect } from 'vitest'
import {
  claveRendicion,
  efectivoAEntregar,
  payloadDeGasto,
  itemsDelCierre,
  totalDelCierre,
  cambiosDelCierre,
  gastosVistos,
  cobrosVistosDe,
  type ItemCierre,
} from './rendicionGastos'
import type { GastoDeRendicion } from '../types/gastos'

const combustible: GastoDeRendicion = {
  id: 7, sucursal_id: 1, compartido: false, fecha: '2026-10-28', rubro_id: 1,
  monto_total: 50000, comprobante: 'factura_a', comprobante_numero: '0005-00012345',
  alicuota_iva: 21, iva: 8677.69, percepcion_iva: 0, percepcion_iibb: 0, otros_impuestos: 0,
  neto: 41322.31, costo: 41322.31, vehiculo_id: 3, litros: 38.5, mes_imputado: '2026-10-01',
  repartir_meses: 1, mes_fin: '2026-10-01', origen_pago: 'rendicion',
  rendicion_transportista_id: 'tr-1', rendicion_fecha: '2026-10-28', empleado_id: null,
  observacion: null, creado_por: 'u-1', anulado_at: null, created_at: '2026-10-28T10:00:00Z',
  rubro: { id: 1, nombre: 'Combustible', grupo: 'vehiculos' },
  vehiculo: { id: 3, patente: 'AC456EF', descripcion: 'Partner' },
  km_tablero: 184230,
  // Con microsegundos y huso, como lo devuelve Postgres: tiene que viajar tal cual.
  updated_at: '2026-10-28T13:05:22.123456+00:00',
}

const otro = (id: number, monto: number): GastoDeRendicion => ({
  ...combustible, id, monto_total: monto, updated_at: `2026-10-28T13:05:0${id % 10}.654321+00:00`,
})

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
  it('resta también los faltantes a cargo de empleados', () => {
    expect(efectivoAEntregar(500000, 50000, 100000, 20000)).toBe(330000)
    expect(efectivoAEntregar(500000, 50000, 100000)).toBe(350000)
  })
  it('redondea a dos decimales', () => {
    expect(efectivoAEntregar(100.1, 0.2)).toBe(99.9)
  })
  it('resta también los pagos al personal con esa plata', () => {
    expect(efectivoAEntregar(500000, 50000, 100000)).toBe(350000)
  })
  it('sin el tercero, los pagos al personal valen 0', () => {
    expect(efectivoAEntregar(500000, 50000)).toBe(450000)
  })
  it('da negativo si los gastos y los pagos superan el efectivo', () => {
    expect(efectivoAEntregar(0, 0, 100000)).toBe(-100000)
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
  it('un gasto de la oficina da oficina y no lleva empleado_id', () => {
    const p = payloadDeGasto({ ...combustible, origen_pago: 'oficina', rendicion_transportista_id: null, rendicion_fecha: null })
    expect(p.origen_pago).toBe('oficina')
    expect(p).not.toHaveProperty('empleado_id')
  })
  it('un gasto de un empleado conserva el origen y su empleado_id', () => {
    const p = payloadDeGasto({
      ...combustible, origen_pago: 'empleado', empleado_id: 4, rendicion_transportista_id: null, rendicion_fecha: null,
    })
    expect(p.origen_pago).toBe('empleado')
    expect(p.empleado_id).toBe(4)
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
    const vistos = gastosVistos([otro(7, 1000), otro(8, 2000), otro(9, 3000)])
    expect(cambiosDelCierre(items, vistos, 0)).toEqual({
      vistos: [
        { id: 7, updated_at: '2026-10-28T13:05:07.654321+00:00' },
        { id: 8, updated_at: '2026-10-28T13:05:08.654321+00:00' },
        { id: 9, updated_at: '2026-10-28T13:05:09.654321+00:00' },
      ],
      guardar: [items[1].payload, nuevo],
      quitar: [9],
      pagos_personal_visto: 0,
      faltantes_visto: 0,
    })
  })

  it('manda los faltantes que vio el modal, y 0 si no hay', () => {
    expect(cambiosDelCierre([], [], 0, 5000).faltantes_visto).toBe(5000)
    expect(cambiosDelCierre([], [], 0)).toHaveProperty('faltantes_visto', 0)
  })

  it('manda lo pagado al personal que vio el modal, siempre', () => {
    expect(cambiosDelCierre([], [], 100000).pagos_personal_visto).toBe(100000)
    expect(cambiosDelCierre([], [], 0)).toHaveProperty('pagos_personal_visto', 0)
  })

  it('manda lo cobrado que vio el modal (#1547)', () => {
    const cobros = { efectivo: 100, transferencia: 50, cheque: 0, cuenta_corriente: 0, tarjeta: 0, otros: 0, entregas: 150 }
    expect(cambiosDelCierre([], [], 0, 0, cobros).cobros_visto).toEqual(cobros)
  })
})

describe('cobrosVistosDe (#1547)', () => {
  it('toma de la tarjeta lo cobrado por forma de pago y lo de entregas del día, sin el adelanto de sueldo', () => {
    const tarjeta = {
      total_efectivo: 50000, total_transferencia: 20000, total_cheque: 1000, total_cuenta_corriente: 2000,
      total_tarjeta: 3000, total_otros: 400, total_adelanto_sueldo: 9999, total_general: 76400,
      total_entregas: 60000, total_ctascte: 16400,
    }
    expect(cobrosVistosDe(tarjeta)).toEqual({
      efectivo: 50000, transferencia: 20000, cheque: 1000, cuenta_corriente: 2000, tarjeta: 3000, otros: 400, entregas: 60000,
    })
  })
})

describe('gastosVistos', () => {
  it('lleva el id y el updated_at tal como llegaron, sin reformatear la fecha', () => {
    expect(gastosVistos([combustible])).toEqual([{ id: 7, updated_at: '2026-10-28T13:05:22.123456+00:00' }])
  })
})

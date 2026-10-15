import { describe, it, expect } from 'vitest'
import { quitarCombosDelPayload } from './pedidoSinCombos'

const payload = {
  offlineUuid: 'u-1',
  clienteId: 7,
  total: 13500,
  totalNeto: 11157.02,
  totalIva: 2342.98,
  items: [
    { productoId: '10', cantidad: 1, precioUnitario: 8800, comboId: '5', precioSinCombo: 10000,
      neto_unitario: 7272.73, iva_unitario: 1527.27, impuestos_internos_unitario: 0, porcentaje_iva: 21 },
    { productoId: '11', cantidad: 1, precioUnitario: 2200, comboId: '5', precioSinCombo: 2500,
      neto_unitario: 1818.18, iva_unitario: 381.82, impuestos_internos_unitario: 0, porcentaje_iva: 21 },
    { productoId: '11', cantidad: 1, precioUnitario: 2500,
      neto_unitario: 2066.12, iva_unitario: 433.88, impuestos_internos_unitario: 0, porcentaje_iva: 21 },
    { productoId: '12', cantidad: 1, precioUnitario: 0, esBonificacion: true, promocionId: '3' },
  ],
}

describe('quitarCombosDelPayload', () => {
  it('pasa las líneas de combo a su precio sin combo y recalcula el total', () => {
    const r = quitarCombosDelPayload(payload) as { items: Array<Record<string, unknown>>; total: number; combosQuitados: boolean }
    expect(r.items.map(i => [i.productoId, i.precioUnitario, 'comboId' in i])).toEqual([
      ['10', 10000, false],
      ['11', 2500, false],
      ['11', 2500, false],
      ['12', 0, false],
    ])
    expect(r.total).toBe(15000)
    expect(r.combosQuitados).toBe(true)
  })

  it('escala el desglose fiscal de las líneas que cambian de precio', () => {
    const r = quitarCombosDelPayload(payload) as { items: Array<Record<string, number>>; totalNeto: number }
    expect(r.items[0].neto_unitario).toBeCloseTo(7272.73 * 10000 / 8800, 2)
    expect(r.items[2].neto_unitario).toBe(2066.12)
  })

  it('conserva la clave de idempotencia y los regalos', () => {
    const r = quitarCombosDelPayload(payload) as Record<string, unknown>
    expect(r.offlineUuid).toBe('u-1')
    expect((r.items as Array<Record<string, unknown>>)[3]).toEqual(payload.items[3])
  })

  it('null si el pedido no tiene combos', () => {
    expect(quitarCombosDelPayload({ items: [{ productoId: '1', cantidad: 1, precioUnitario: 5 }] })).toBeNull()
  })
})

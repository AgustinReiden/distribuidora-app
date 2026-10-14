import { describe, it, expect } from 'vitest'
import { quitarRegalosDelPayload } from './pedidoSinRegalos'

const payload = {
  offlineUuid: 'uuid-1',
  clienteId: '10',
  total: 1000,
  totalNeto: 826.45,
  totalIva: 0,
  fecha: '2026-10-13',
  items: [
    { productoId: '1', cantidad: 10, precioUnitario: 100 },
    { productoId: '2', cantidad: 4, precioUnitario: 0, esBonificacion: true, promocionId: '15', regaloMueveStock: true },
    { productoId: '3', cantidad: 1, precioUnitario: 0, esBonificacion: true, promocionId: '16' },
  ],
  origenes: [
    { producto_id: '1', es_bonificacion: false, origen_precio: 'lista' },
    { producto_id: '2', es_bonificacion: true, origen_precio: 'bonificacion' },
    { producto_id: '3', es_bonificacion: true, origen_precio: 'bonificacion' },
  ],
}

describe('quitarRegalosDelPayload (#1153)', () => {
  it('saca todas las líneas de regalo y sus orígenes, y marca el payload', () => {
    const r = quitarRegalosDelPayload(payload)!
    expect(r.items).toEqual([{ productoId: '1', cantidad: 10, precioUnitario: 100 }])
    expect(r.origenes).toEqual([{ producto_id: '1', es_bonificacion: false, origen_precio: 'lista' }])
    expect(r.regalosQuitados).toBe(true)
  })

  it('no toca los totales, la fecha ni la clave de idempotencia', () => {
    const r = quitarRegalosDelPayload(payload)!
    expect(r.offlineUuid).toBe('uuid-1')
    expect(r.total).toBe(1000)
    expect(r.totalNeto).toBe(826.45)
    expect(r.totalIva).toBe(0)
    expect(r.fecha).toBe('2026-10-13')
    expect(r.clienteId).toBe('10')
  })

  it('no muta el payload original', () => {
    const copia = JSON.parse(JSON.stringify(payload))
    quitarRegalosDelPayload(payload)
    expect(payload).toEqual(copia)
  })

  it('sin regalos devuelve null', () => {
    expect(quitarRegalosDelPayload({ ...payload, items: [payload.items[0]] })).toBeNull()
    expect(quitarRegalosDelPayload({ ...payload, items: [] })).toBeNull()
    expect(quitarRegalosDelPayload({ clienteId: '10' })).toBeNull()
  })

  it('sin orígenes no los inventa', () => {
    const { origenes: _o, ...sinOrigenes } = payload
    const r = quitarRegalosDelPayload(sinOrigenes)!
    expect('origenes' in r).toBe(false)
    expect(r.items).toHaveLength(1)
  })
})

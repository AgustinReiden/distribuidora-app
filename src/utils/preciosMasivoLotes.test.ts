import { describe, it, expect } from 'vitest'
import {
  armarLotesPreciosMasivo,
  escalasDeSeleccion,
  type CondicionParaMasivo,
  type ItemPrecioMasivo,
} from './preciosMasivoLotes'

const item = (id: number | string): ItemPrecioMasivo => ({ producto_id: String(id), precio_neto: null, imp_internos: null, precio_final: 110 })

const condicion = (id: number, productos: number[], escalas: Array<[number, number, number]>, overrides: Record<number, Array<[number, number]>> = {}): CondicionParaMasivo => ({
  id,
  nombre: `Condición ${id}`,
  productos: productos.map(p => ({ producto_id: String(p) })),
  escalas: escalas.map(([eid, cantidad, precio]) => ({ id: eid, cantidad_minima: cantidad, precio_unitario: precio })),
  escalaMinimos: Object.fromEntries(Object.entries(overrides).map(([eid, ms]) => [eid, ms.map(([p, o]) => ({ producto_id: String(p), precio_unitario_override: o }))])),
})

describe('escalasDeSeleccion (#1561, CAT-7)', () => {
  it('ofrece las escalas de una condición con todos sus productos elegidos, con el mismo porcentaje y redondeo', () => {
    // Lista de 100 a 200: la escala de 10 u. a 90 pasa a 180, y el precio por producto de 85 a 170.
    const r = escalasDeSeleccion([condicion(1, [1, 2], [[11, 10, 90]], { 11: [[1, 85]] })], new Set(['1', '2']), 100)
    expect(r.parciales).toBe(0)
    expect(r.aplicables).toHaveLength(1)
    expect(r.aplicables[0].escala).toEqual({ escala_id: '11', precio_unitario: 180, minimos: [{ producto_id: '1', precio_unitario_override: 170 }] })
    expect(r.aplicables[0].productoIds).toEqual(['1', '2'])
  })

  it('la de una condición elegida a medias no se ofrece: se cuenta aparte para avisar', () => {
    const r = escalasDeSeleccion([condicion(1, [1, 2], [[11, 10, 90], [12, 20, 80]])], new Set(['1']), 10)
    expect(r.aplicables).toHaveLength(0)
    expect(r.parciales).toBe(2)
    expect(r.condicionesParciales).toEqual(['Condición 1'])
  })

  it('ignora las condiciones sin productos elegidos y las que no tienen escalas', () => {
    const r = escalasDeSeleccion([condicion(1, [1], [[11, 10, 90]]), condicion(2, [2], [])], new Set(['2']), 10)
    expect(r.aplicables).toHaveLength(0)
    expect(r.parciales).toBe(0)
  })

  it('los precios por producto vacíos no viajan', () => {
    const c = condicion(1, [1], [[11, 10, 90]])
    c.escalaMinimos = { 11: [{ producto_id: '1', precio_unitario_override: null }] }
    const r = escalasDeSeleccion([c], new Set(['1']), 10)
    expect(r.aplicables[0].escala.minimos).toEqual([])
  })
})

describe('armarLotesPreciosMasivo (#1561, CAT-6)', () => {
  it('parte 1.201 productos sueltos en lotes de 500', () => {
    const items = Array.from({ length: 1201 }, (_, i) => item(i + 1))
    const { lotes } = armarLotesPreciosMasivo(items, [])
    expect(lotes.map(l => l.items.length)).toEqual([500, 500, 201])
    expect(lotes.flatMap(l => l.items)).toEqual(items)
  })

  it('una condición va entera en un lote, con su escala', () => {
    const items = Array.from({ length: 10 }, (_, i) => item(i + 1))
    const { aplicables } = escalasDeSeleccion([condicion(1, [3, 4, 5, 6], [[11, 10, 90]])], new Set(items.map(i => i.producto_id)), 10)
    const { lotes } = armarLotesPreciosMasivo(items, aplicables, 4)
    const conEscala = lotes.filter(l => l.escalas.length > 0)
    expect(conEscala).toHaveLength(1)
    expect(conEscala[0].items.map(i => i.producto_id).sort()).toEqual(['3', '4', '5', '6'])
    expect(lotes.flatMap(l => l.items.map(i => i.producto_id)).sort()).toEqual(items.map(i => i.producto_id).sort())
    expect(lotes.every(l => l.items.length <= 4)).toBe(true)
  })

  it('dos condiciones que comparten un producto van juntas', () => {
    const items = [1, 2, 3, 4, 5].map(item)
    const sel = new Set(items.map(i => i.producto_id))
    const { aplicables } = escalasDeSeleccion([condicion(1, [1, 2], [[11, 10, 90]]), condicion(2, [2, 3], [[21, 10, 90]])], sel, 10)
    const { lotes } = armarLotesPreciosMasivo(items, aplicables, 3)
    const lote = lotes.find(l => l.escalas.length > 0)!
    expect(lote.escalas.map(e => e.escala_id).sort()).toEqual(['11', '21'])
    expect(lote.items.map(i => i.producto_id).sort()).toEqual(['1', '2', '3'])
  })

  it('una escala cuyos productos no están todos en la lista no viaja', () => {
    const { aplicables } = escalasDeSeleccion([condicion(1, [1, 2], [[11, 10, 90]])], new Set(['1', '2']), 10)
    const { lotes } = armarLotesPreciosMasivo([item(1)], aplicables)
    expect(lotes.flatMap(l => l.escalas)).toEqual([])
  })

  it('una condición más grande que el tope del server va partida y sin sus escalas', () => {
    const ids = Array.from({ length: 12 }, (_, i) => i + 1)
    const { aplicables } = escalasDeSeleccion([condicion(1, ids, [[11, 10, 90]])], new Set(ids.map(String)), 10)
    const { lotes, descartadas } = armarLotesPreciosMasivo(ids.map(item), aplicables, 5, 10)
    expect(descartadas).toHaveLength(1)
    expect(lotes.flatMap(l => l.escalas)).toEqual([])
    expect(lotes.map(l => l.items.length)).toEqual([5, 5, 2])
  })
})

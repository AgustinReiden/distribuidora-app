import { describe, it, expect } from 'vitest'
import { sugerirMatchProducto, separarPorActivo, armarResoluciones, avisoAceptacion, estaDesactivado } from './matchProducto'
import type { ProductoDB } from '../types'

const p = (id: string, nombre: string, codigo: string | null, activo?: boolean) =>
  ({ id, nombre, codigo, precio: 1, stock: 0, activo }) as ProductoDB

describe('sugerirMatchProducto (#1558, D7)', () => {
  it('no sugiere un producto desactivado, ni por código ni por nombre', () => {
    const productos = [p('1', 'Agua 500', 'A5', false), p('2', 'Agua 500 nueva', 'A5N')]
    expect(sugerirMatchProducto({ codigo: 'A5', nombre: 'Agua 500' }, productos)).toBeNull()
  })

  it('con un activo y un desactivado iguales, sugiere el activo', () => {
    const productos = [p('1', 'Soda', 'S1', false), p('2', 'Soda', 'S1', true)]
    expect(sugerirMatchProducto({ codigo: 'S1', nombre: 'Soda' }, productos)?.id).toBe('2')
  })

  it('sin el dato de activo, cuenta como activo (lo de antes)', () => {
    expect(sugerirMatchProducto({ codigo: 'X' }, [p('9', 'X', 'X')])?.id).toBe('9')
    expect(estaDesactivado({})).toBe(false)
  })
})

describe('separarPorActivo', () => {
  it('pone los desactivados aparte, en su orden', () => {
    const { activos, desactivados } = separarPorActivo([p('1', 'a', null, false), p('2', 'b', null), p('3', 'c', null, false)])
    expect(activos.map(x => x.id)).toEqual(['2'])
    expect(desactivados.map(x => x.id)).toEqual(['1', '3'])
  })
})

describe('armarResoluciones', () => {
  it('marca reactivar sólo en el item que se confirmó', () => {
    expect(armarResoluciones([10, 11, 12], { 10: '5', 11: '6', 12: '__nuevo__' }, { 11: true }, '__nuevo__')).toEqual([
      { item_id: 10, accion: 'match_existente', producto_destino_id: 5 },
      { item_id: 11, accion: 'match_existente', producto_destino_id: 6, reactivar: true },
      { item_id: 12, accion: 'crear_nuevo' },
    ])
  })

  it('un item sin elegir se crea nuevo, aunque tenga la marca', () => {
    expect(armarResoluciones([7], {}, { 7: true }, '__nuevo__')).toEqual([{ item_id: 7, accion: 'crear_nuevo' }])
  })
})

describe('avisoAceptacion', () => {
  const productos = [p('5', 'Agua 500', null), p('6', 'Soda', null)]
  it('sin reactivados, el aviso de siempre', () => {
    expect(avisoAceptacion([], productos)).toBe('Movimiento aceptado. Stock ingresado en esta sucursal.')
  })
  it('nombra los reactivados', () => {
    expect(avisoAceptacion([5], productos)).toBe('Movimiento aceptado. Stock ingresado en esta sucursal. Se reactivó: Agua 500.')
    expect(avisoAceptacion([5, 6], productos)).toBe('Movimiento aceptado. Stock ingresado en esta sucursal. Se reactivaron: Agua 500, Soda.')
  })
})

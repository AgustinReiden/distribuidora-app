import { describe, it, expect } from 'vitest'
import {
  esProductoOperativo,
  esProductoMostrable,
  filtrarProductosOperativos,
  esErrorPorHistorial,
  mensajeErrorAlEliminarProducto,
  itemsConProductoDesactivado,
} from './productosOperativos'

describe('esProductoOperativo', () => {
  it.each([
    [true, true],
    [false, false],
    [undefined, true],
    [null, true],
  ])('activo=%s -> %s', (activo, esperado) => {
    expect(esProductoOperativo({ activo })).toBe(esperado)
  })
})

describe('esProductoMostrable', () => {
  const casos: Array<[boolean | undefined, number | string | null | undefined, boolean, boolean]> = [
    // activo, stock, mostrarSinStock, esperado
    [true, 5, true, true],
    [true, 5, false, true],
    [true, 0, true, true],
    [true, 0, false, false],
    [true, -3, false, false],
    [true, -3, true, true],
    [true, '4', false, true],
    [true, null, false, false],
    [true, undefined, true, true],
    [undefined, 5, false, true],
    [undefined, 0, false, false],
    [false, 5, true, false],
    [false, 5, false, false],
    [false, 0, true, false],
    [false, 0, false, false],
  ]
  it.each(casos)('activo=%s stock=%s mostrarSinStock=%s -> %s', (activo, stock, mostrarSinStock, esperado) => {
    expect(esProductoMostrable({ activo, stock }, { mostrarSinStock })).toBe(esperado)
  })
})

describe('filtrarProductosOperativos', () => {
  it('descarta sólo los inactivos y conserva el orden', () => {
    const lista = [
      { id: 1, activo: true },
      { id: 2, activo: false },
      { id: 3 },
      { id: 4, activo: false },
      { id: 5, activo: true },
    ]
    expect(filtrarProductosOperativos(lista).map(p => p.id)).toEqual([1, 3, 5])
  })
})

describe('esErrorPorHistorial', () => {
  it('reconoce el mensaje del trigger, sea Error u objeto plano de supabase-js', () => {
    expect(esErrorPorHistorial(new Error('No se puede eliminar: el producto tiene historial'))).toBe(true)
    expect(esErrorPorHistorial({ message: 'Producto con Historial de ventas', code: 'P0001' })).toBe(true)
  })
  it('no confunde otros errores', () => {
    expect(esErrorPorHistorial(new Error('Failed to fetch'))).toBe(false)
    expect(esErrorPorHistorial({ message: 'violates foreign key', code: '23503' })).toBe(false)
    expect(esErrorPorHistorial(null)).toBe(false)
    expect(esErrorPorHistorial(undefined)).toBe(false)
  })
})

// 1561-b2 (#1561, decisión del dueño): con stock, con lotes o como regalo de una promo
// tampoco se borra, y el motivo que da la base es lo que ve el usuario.
describe('mensajeErrorAlEliminarProducto', () => {
  it('con stock, lotes o una promo muestra el motivo de la base tal cual', () => {
    const base = 'No se puede borrar "Agua de ensayo": tiene 5 u. en stock, tiene lotes. Desactivalo en lugar de borrarlo.'
    expect(mensajeErrorAlEliminarProducto({ message: base, code: '23503' })).toBe(base)
  })
  it('con historial conserva su texto', () => {
    expect(mensajeErrorAlEliminarProducto({
      message: 'No se puede borrar "Agua": tiene historial (pedidos). Desactivalo en lugar de borrarlo.',
      code: '23503',
    })).toBe('No se puede eliminar: tiene historial. Desactivalo para que deje de ofrecerse.')
  })
  it('otro error no muestra lo crudo', () => {
    expect(mensajeErrorAlEliminarProducto({ message: 'violates foreign key', code: '23503' }))
      .toBe('Error al eliminar producto')
    expect(mensajeErrorAlEliminarProducto(null)).toBe('Error al eliminar producto')
  })
})

describe('itemsConProductoDesactivado', () => {
  const catalogo = [
    { id: 'a', nombre: 'A', activo: true },
    { id: 'b', nombre: 'B', activo: false },
    { id: 'c', nombre: 'C' },
  ]
  it('detecta desactivados, incluso en una línea de regalo, sin duplicar', () => {
    const items = [
      { productoId: 'a' },
      { productoId: 'b' },
      { productoId: 'b', esBonificacion: true },
      { productoId: 'c' },
    ]
    expect(itemsConProductoDesactivado(items, catalogo)).toEqual([{ productoId: 'b', nombre: 'B' }])
  })
  it('no juzga lo que no está en el catálogo', () => {
    expect(itemsConProductoDesactivado([{ productoId: 'zzz' }], catalogo)).toEqual([])
  })
})

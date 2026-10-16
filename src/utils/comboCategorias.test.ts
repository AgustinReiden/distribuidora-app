import { describe, it, expect } from 'vitest'
import { productosDeCategoria, productosEnVariosLugares, resolverLugares, type ProductoCatalogo } from './comboCategorias'

// Rubro "alpha" (A) con el subrubro "alpha 1l" (S); "pindapoy" (P) aparte.
const catalogo: ProductoCatalogo[] = [
  { id: 1, activo: true, categoria_id: 'A' },
  { id: 2, activo: true, categoria_id: 'A', subcategoria_id: 'S' },
  { id: 3, activo: false, categoria_id: 'A' },
  { id: 10, activo: true, categoria_id: 'P' },
  { id: 20, activo: true, categoria_id: null },
]

describe('productosDeCategoria', () => {
  it('un rubro trae sus productos activos, también los de sus subrubros', () => {
    expect(productosDeCategoria('A', catalogo)).toEqual(['1', '2'])
  })
  it('un subrubro trae sólo los suyos', () => {
    expect(productosDeCategoria('S', catalogo)).toEqual(['2'])
  })
  it('una categoría sin productos activos queda vacía', () => {
    expect(productosDeCategoria('X', catalogo)).toEqual([])
  })
})

describe('resolverLugares', () => {
  it('une sueltos y categorías, sin inactivos y ordenado por id', () => {
    expect(resolverLugares(
      [{ cantidad: 1, sueltos: [], categorias: ['A'] }, { cantidad: 1, sueltos: ['20'], categorias: ['P'] }],
      catalogo,
    )).toEqual([{ cantidad: 1, productos: ['1', '2'] }, { cantidad: 1, productos: ['10', '20'] }])
  })
  it('un suelto inactivo se conserva, como en el server', () => {
    expect(resolverLugares([{ cantidad: 2, sueltos: ['3'], categorias: [] }], catalogo))
      .toEqual([{ cantidad: 2, productos: ['3'] }])
  })
  it('un producto que cae en dos lugares queda en el de número más bajo', () => {
    expect(resolverLugares(
      [{ cantidad: 1, sueltos: ['2'], categorias: [] }, { cantidad: 1, sueltos: [], categorias: ['A'] }],
      catalogo,
    )).toEqual([{ cantidad: 1, productos: ['2'] }, { cantidad: 1, productos: ['1'] }])
  })
  it('la categoría es viva: un producto nuevo del rubro entra', () => {
    const conNuevo = [...catalogo, { id: 4, activo: true, categoria_id: 'A' }]
    expect(resolverLugares([{ cantidad: 1, sueltos: [], categorias: ['A'] }], conNuevo)[0].productos)
      .toEqual(['1', '2', '4'])
  })
  it('un lugar cuya categoría se vació queda sin productos', () => {
    expect(resolverLugares([{ cantidad: 1, sueltos: [], categorias: ['X'] }], catalogo))
      .toEqual([{ cantidad: 1, productos: [] }])
  })
})

describe('productosEnVariosLugares', () => {
  it('avisa el producto suelto que ya trae la categoría de otro lugar', () => {
    expect(productosEnVariosLugares(
      [{ cantidad: 1, sueltos: [], categorias: ['A'] }, { cantidad: 1, sueltos: ['1'], categorias: [] }],
      catalogo,
    )).toEqual(['1'])
  })
  it('dentro de un mismo lugar categoría y suelto se superponen sin aviso', () => {
    expect(productosEnVariosLugares([{ cantidad: 2, sueltos: ['1'], categorias: ['A', 'S'] }], catalogo)).toEqual([])
  })
})

import { describe, it, expect } from 'vitest'
import { detallesTop, nombresTop } from './topGerencial'

describe('detallesTop (#1472)', () => {
  it('un nombre que no se repite va sin detalle', () => {
    expect(detallesTop([
      { id: 1, nombre: 'Junior', detalle: 'Junior SRL' },
      { id: 2, nombre: 'Daniel Lai', detalle: 'Daniel Lai' },
    ])).toEqual([null, null])
  })

  it('dos clientes que se llaman igual se distinguen por la razón social', () => {
    expect(detallesTop([
      { id: 10, nombre: 'Kiosco ', detalle: 'Pérez Juan' },
      { id: 11, nombre: 'Daniel Lai', detalle: 'Daniel Lai' },
      { id: 12, nombre: 'kiosco', detalle: 'Gómez Ana' },
    ])).toEqual(['Pérez Juan', null, 'Gómez Ana'])
  })

  it('sin razón social, igual al nombre o repetida, va el id', () => {
    expect(detallesTop([
      { id: 10, nombre: 'Kiosco', detalle: 'Kiosco' },
      { id: 11, nombre: 'Kiosco', detalle: null },
      { id: 12, nombre: 'Kiosco', detalle: 'López' },
      { id: 13, nombre: 'Kiosco', detalle: 'López' },
    ])).toEqual(['#10', '#11', '#12', '#13'])
  })

  it('el mismo producto en dos sucursales se distingue por la sucursal', () => {
    expect(detallesTop([
      { id: 246, nombre: 'CHEESEBURGUER 85 GRS', detalle: 'Tucumán' },
      { id: 344, nombre: 'CHEESEBURGUER 85 GRS', detalle: 'Taco Pozo' },
    ])).toEqual(['Tucumán', 'Taco Pozo'])
  })

  it('las líneas de productos borrados (sin id) no llevan id', () => {
    expect(detallesTop([
      { id: null, nombre: '(producto borrado)', detalle: null },
      { id: 5, nombre: '(producto borrado)', detalle: null },
    ])).toEqual([null, '#5'])
  })
})

describe('nombresTop', () => {
  it('agrega el detalle entre paréntesis sólo a los repetidos', () => {
    expect(nombresTop([
      { id: 10, nombre: 'Kiosco', detalle: 'Pérez Juan' },
      { id: 12, nombre: 'Kiosco', detalle: 'Gómez Ana' },
      { id: 13, nombre: 'Junior', detalle: 'Junior SRL' },
    ])).toEqual(['Kiosco (Pérez Juan)', 'Kiosco (Gómez Ana)', 'Junior'])
  })
})

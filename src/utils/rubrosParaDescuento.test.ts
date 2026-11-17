import { describe, it, expect } from 'vitest'
import { rubrosParaDescuento } from './rubrosParaDescuento'

const tabla = [
  { nombre: 'Gaseosas', activa: true },
  { nombre: 'Aguas', activa: true },
  { nombre: 'Vinos', activa: false },
]

describe('rubrosParaDescuento (CAT-11)', () => {
  it('une la tabla y los rubros de los productos, sin repetir y ordenados', () => {
    expect(rubrosParaDescuento(tabla, ['Gaseosas', 'Snacks', ' Aguas '])).toEqual(['Aguas', 'Gaseosas', 'Snacks'])
  })

  it('un rubro desactivado no se ofrece, ni por la tabla ni porque un producto lo conserva', () => {
    expect(rubrosParaDescuento(tabla, ['Vinos'])).not.toContain('Vinos')
  })

  it('pero el cliente que ya tiene un descuento sobre un rubro desactivado lo sigue viendo', () => {
    expect(rubrosParaDescuento(tabla, ['Vinos'], ['Vinos'])).toContain('Vinos')
  })

  it('ignora vacíos y nulos', () => {
    expect(rubrosParaDescuento([{ nombre: null }, { nombre: '  ' }], [null, undefined, ''])).toEqual([])
  })
})

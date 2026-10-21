import { describe, it, expect } from 'vitest'
import { PRECIO_PENDIENTE, tienePrecioDeVenta } from './precioVenta'

describe('tienePrecioDeVenta', () => {
  it('un precio positivo es un precio de venta', () => {
    expect(tienePrecioDeVenta({ precio: 7400 })).toBe(true)
    expect(tienePrecioDeVenta({ precio: 0.01 })).toBe(true)
  })

  it('PostgREST manda los numeric como string', () => {
    expect(tienePrecioDeVenta({ precio: '7400.00' })).toBe(true)
    expect(tienePrecioDeVenta({ precio: '0.00' })).toBe(false)
  })

  it('0, negativo, null, vacío o ausente es "sin precio"', () => {
    expect(tienePrecioDeVenta({ precio: 0 })).toBe(false)
    expect(tienePrecioDeVenta({ precio: -1 })).toBe(false)
    expect(tienePrecioDeVenta({ precio: null })).toBe(false)
    expect(tienePrecioDeVenta({ precio: '' })).toBe(false)
    expect(tienePrecioDeVenta({})).toBe(false)
    expect(tienePrecioDeVenta({ precio: 'abc' })).toBe(false)
  })

  it('el precio pendiente es "sin precio"', () => {
    expect(tienePrecioDeVenta({ precio: PRECIO_PENDIENTE })).toBe(false)
  })
})

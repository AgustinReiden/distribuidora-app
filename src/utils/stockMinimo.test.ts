import { describe, it, expect } from 'vitest'
import { stockBajo, stockMinimoEfectivo, tieneAlertaDeStock } from './stockMinimo'

describe('stock mínimo (CAT-13)', () => {
  it('vacío usa 10', () => {
    expect(stockMinimoEfectivo(null)).toBe(10)
    expect(stockMinimoEfectivo(undefined)).toBe(10)
    expect(stockMinimoEfectivo('')).toBe(10)
  })

  it('0 es 0 (sin alerta), no 10', () => {
    expect(stockMinimoEfectivo(0)).toBe(0)
    expect(tieneAlertaDeStock(0)).toBe(false)
    expect(tieneAlertaDeStock(null)).toBe(true)
  })

  it('un mínimo de 0 nunca está bajo, ni con stock 0', () => {
    expect(stockBajo(0, 0)).toBe(false)
    expect(stockBajo(5, 0)).toBe(false)
  })

  it('está bajo en el mínimo y por debajo (<=), no por encima', () => {
    expect(stockBajo(9, 10)).toBe(true)
    expect(stockBajo(10, 10)).toBe(true)
    expect(stockBajo(11, 10)).toBe(false)
  })

  it('sin dato usa 10', () => {
    expect(stockBajo(10, null)).toBe(true)
    expect(stockBajo(11, undefined)).toBe(false)
  })

  it('tolera un mínimo que llega como texto de la base', () => {
    expect(stockBajo(3, '5')).toBe(true)
    expect(stockBajo(3, '0')).toBe(false)
  })
})

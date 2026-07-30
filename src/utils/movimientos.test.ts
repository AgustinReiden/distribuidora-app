import { describe, it, expect } from 'vitest'
import { stockDisponibleParaEnvio } from './movimientos'

describe('stockDisponibleParaEnvio', () => {
  it('al crear (sin reserva previa) el tope es el stock actual', () => {
    expect(stockDisponibleParaEnvio(50)).toBe(50)
    expect(stockDisponibleParaEnvio(50, 0)).toBe(50)
  })

  it('al editar suma lo que este envío ya se llevó', () => {
    // El envío tiene 10 u. reservadas y en góndola quedan 40 -> se puede llegar a 50.
    expect(stockDisponibleParaEnvio(40, 10)).toBe(50)
  })

  it('permite bajar la cantidad aunque el producto haya quedado en 0', () => {
    // Caso real: el envío se llevó todo. Sin sumar la reserva el tope sería 0
    // y no se podría ni corregir el envío hacia abajo.
    expect(stockDisponibleParaEnvio(0, 100)).toBe(100)
  })

  it('nunca devuelve negativo', () => {
    expect(stockDisponibleParaEnvio(-5)).toBe(0)
    expect(stockDisponibleParaEnvio(-10, 3)).toBe(0)
  })

  it('tolera valores no numéricos', () => {
    expect(stockDisponibleParaEnvio(NaN)).toBe(0)
    expect(stockDisponibleParaEnvio(10, NaN)).toBe(10)
  })
})

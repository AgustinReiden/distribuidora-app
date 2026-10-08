import { describe, expect, it } from 'vitest'
import { esAdelantoSueldo, filtrarPagosPorForma, filtroEfectivo, totalAdelantosSueldo } from './adelantosSueldo'

const pagos = [
  { id: 1, forma_pago: 'efectivo', monto: 1000 },
  { id: 2, forma_pago: 'adelanto_sueldo', monto: 2500.5 },
  { id: 3, forma_pago: 'tarjeta', monto: 300 },
  { id: 4, forma_pago: 'adelanto_sueldo', monto: '499.5' },
  { id: 5, forma_pago: null, monto: 10 },
]

describe('adelantosSueldo', () => {
  it('detecta solo adelanto_sueldo (tarjeta no)', () => {
    expect(pagos.filter(esAdelantoSueldo).map(p => p.id)).toEqual([2, 4])
  })

  it('filtra por forma; "todos" devuelve todo', () => {
    expect(filtrarPagosPorForma(pagos, 'todos')).toHaveLength(5)
    expect(filtrarPagosPorForma(pagos, 'adelanto_sueldo').map(p => p.id)).toEqual([2, 4])
  })

  it('si no quedan adelantos, el filtro cae a "todos" (no deja la lista vacía)', () => {
    const sinAdelantos = pagos.filter(p => !esAdelantoSueldo(p))
    const hay = sinAdelantos.some(esAdelantoSueldo)
    expect(filtroEfectivo('adelanto_sueldo', hay)).toBe('todos')
    expect(filtrarPagosPorForma(sinAdelantos, filtroEfectivo('adelanto_sueldo', hay))).toHaveLength(3)
    expect(filtroEfectivo('adelanto_sueldo', true)).toBe('adelanto_sueldo')
  })

  it('suma los adelantos (acepta monto numérico o string)', () => {
    expect(totalAdelantosSueldo(pagos)).toBe(3000)
    expect(totalAdelantosSueldo([])).toBe(0)
  })
})

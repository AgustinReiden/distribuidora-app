import { describe, it, expect } from 'vitest'
import { margenNetoMesPct } from './formato'

describe('margenNetoMesPct', () => {
  it('venta − CMV − bonif. sobre la venta', () => {
    expect(margenNetoMesPct({ venta: 100000, cmv: 60000, bonif: 5000 })).toBeCloseTo(0.35, 6)
  })

  it('los descuentos de proveedores (mig 280) suman al margen, como en los kpis', () => {
    expect(margenNetoMesPct({ venta: 100000, cmv: 60000, bonif: 5000, descuentos_proveedores: 2000 })).toBeCloseTo(0.37, 6)
  })

  it('un mes sin venta da 0, no NaN', () => {
    expect(margenNetoMesPct({ venta: 0, cmv: 0, bonif: 0, descuentos_proveedores: 500 })).toBe(0)
  })
})

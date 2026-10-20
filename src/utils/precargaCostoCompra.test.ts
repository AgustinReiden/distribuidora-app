import { describe, it, expect } from 'vitest'
import { precargaConBonificacion } from './precargaCostoCompra'

describe('precargaConBonificacion', () => {
  it('Rivoli con 9%: precarga el neto de lista y el 9%, no el neto bonificado', () => {
    // Neto de lista 1000, bonif 9% → costo_sin_iva guardado 910.
    expect(precargaConBonificacion(910, { costoUnitario: 1000, bonificacion: 9 }))
      .toEqual({ costoUnitario: 1000, bonificacion: 9 })
  })

  it('tolera el redondeo a centavos de costo_sin_iva', () => {
    // 1234.56 × 0.91 = 1123.4496 → guardado 1123.45
    expect(precargaConBonificacion(1123.45, { costoUnitario: 1234.56, bonificacion: 9 }))
      .toEqual({ costoUnitario: 1234.56, bonificacion: 9 })
  })

  it('sin bonificación en la anterior no cambia nada', () => {
    expect(precargaConBonificacion(1000, { costoUnitario: 1000, bonificacion: 0 })).toBeNull()
  })

  it('sin compra anterior no cambia nada', () => {
    expect(precargaConBonificacion(910, null)).toBeNull()
    expect(precargaConBonificacion(910, undefined)).toBeNull()
  })

  it('si el costo vigente no sale de esa línea (se tocó después), no la usa', () => {
    // La ficha dice 950: alguien lo cambió a mano, la anterior ya no es la fuente.
    expect(precargaConBonificacion(950, { costoUnitario: 1000, bonificacion: 9 })).toBeNull()
  })

  it('una línea 100% bonificada (regalo) no se usa de base', () => {
    expect(precargaConBonificacion(0, { costoUnitario: 1000, bonificacion: 100 })).toBeNull()
  })

  it('datos raros de la anterior no rompen', () => {
    expect(precargaConBonificacion(910, { costoUnitario: null, bonificacion: 9 })).toBeNull()
    expect(precargaConBonificacion(910, { costoUnitario: 1000, bonificacion: null })).toBeNull()
  })
})

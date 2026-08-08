import { describe, it, expect } from 'vitest'
import { margenesEscala, descuentoSobreLista } from './margenEscala'

describe('margenesEscala', () => {
  it('calcula bruto sobre el costo total y neto sobre el costo real', () => {
    // Precio 800 con IVA 21 → neto 661.16. Costo total 600, costo real 500.
    const { bruto, neto } = margenesEscala(800, 600, 500, 21)
    expect(bruto).toBeCloseTo(33.3, 1)
    expect(neto).toBeCloseTo(32.2, 1)
  })

  it('sin costo cargado no inventa un margen', () => {
    expect(margenesEscala(800, 0, 0, 21)).toEqual({ bruto: null, neto: null })
  })

  it('sin precio tampoco', () => {
    expect(margenesEscala(0, 600, 500, 21)).toEqual({ bruto: null, neto: null })
  })

  it('un precio por debajo del costo da margen negativo, no null', () => {
    const { bruto } = margenesEscala(500, 600, 500, 21)
    expect(bruto).toBeLessThan(0)
  })

  it('los dos márgenes son independientes: puede faltar solo uno', () => {
    const { bruto, neto } = margenesEscala(800, 600, 0, 21)
    expect(bruto).not.toBeNull()
    expect(neto).toBeNull()
  })
})

describe('descuentoSobreLista', () => {
  it('mide cuánto baja el mayorista respecto de la lista', () => {
    expect(descuentoSobreLista(800, 1000)).toBeCloseTo(20, 5)
  })

  it('da negativo si la condición quedó por encima de la lista', () => {
    // Pasa cuando sube el precio de lista y nadie actualiza la condición.
    expect(descuentoSobreLista(1100, 1000)).toBeCloseTo(-10, 5)
  })

  it('sin precio de lista no hay con qué comparar', () => {
    expect(descuentoSobreLista(800, 0)).toBeNull()
  })

  it('sin precio mayorista tampoco', () => {
    expect(descuentoSobreLista(0, 1000)).toBeNull()
  })
})

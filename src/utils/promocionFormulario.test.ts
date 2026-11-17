import { describe, it, expect } from 'vitest'
import { stockPorBloqueDelFormulario } from './promocionFormulario'

describe('stockPorBloqueDelFormulario', () => {
  it('una promo nueva, o una sin el dato, manda 1', () => {
    expect(stockPorBloqueDelFormulario(undefined)).toBe(1)
    expect(stockPorBloqueDelFormulario(null)).toBe(1)
  })

  it('una promo que ya tiene otro stock por bloque lo conserva (antes el formulario mandaba 1 y lo pisaba)', () => {
    expect(stockPorBloqueDelFormulario(2)).toBe(2)
    expect(stockPorBloqueDelFormulario('3')).toBe(3)
  })

  it('un valor que no es un entero positivo no se manda: 1', () => {
    expect(stockPorBloqueDelFormulario(0)).toBe(1)
    expect(stockPorBloqueDelFormulario(-2)).toBe(1)
    expect(stockPorBloqueDelFormulario(1.5)).toBe(1)
    expect(stockPorBloqueDelFormulario('NaN')).toBe(1)
  })
})

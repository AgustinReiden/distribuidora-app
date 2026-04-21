import { describe, it, expect } from 'vitest'
import { parsePrecio } from './calculations'

describe('parsePrecio', () => {
  it('redondea a 2 decimales', () => {
    expect(parsePrecio('10.456')).toBe(10.46)
    expect(parsePrecio('10.454')).toBe(10.45)
  })

  it('devuelve 0 para strings inválidos', () => {
    expect(parsePrecio('abc')).toBe(0)
    expect(parsePrecio('')).toBe(0)
    expect(parsePrecio(null as unknown as string)).toBe(0)
    expect(parsePrecio(undefined as unknown as string)).toBe(0)
  })

  it('maneja valores numéricos directos', () => {
    expect(parsePrecio(99.999)).toBe(100)
    expect(parsePrecio(0.005)).toBe(0.01)
  })

  it('trunca floating point drift', () => {
    expect(parsePrecio(0.1 + 0.2)).toBe(0.3)
  })

  it('acepta comas como separador decimal (es-AR)', () => {
    expect(parsePrecio('10,5')).toBe(10.5)
    expect(parsePrecio('1.234,56')).toBe(1234.56)
  })

  it('trimea whitespace en strings', () => {
    expect(parsePrecio('  10,50  ')).toBe(10.5)
    expect(parsePrecio('\t99.99\n')).toBe(99.99)
  })

  it('maneja números negativos', () => {
    expect(parsePrecio('-10.50')).toBe(-10.5)
    expect(parsePrecio('-0,01')).toBe(-0.01)
    expect(parsePrecio(-99.999)).toBe(-100)
  })

  it('devuelve 0 para Infinity y NaN', () => {
    expect(parsePrecio(Infinity)).toBe(0)
    expect(parsePrecio(-Infinity)).toBe(0)
    expect(parsePrecio(NaN)).toBe(0)
  })
})

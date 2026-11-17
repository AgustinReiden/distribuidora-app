import { describe, it, expect } from 'vitest'
import { mismoTotalDelAlta } from './totalDelAlta'

describe('mismoTotalDelAlta (hallazgo 5 de la revisión de B4, 1559-b1)', () => {
  it('un centavo de diferencia es el mismo total, sin depender de la coma flotante', () => {
    expect(Math.abs(99.99 - 100) < 0.01).toBe(false)
    expect(mismoTotalDelAlta(99.99, 100)).toBe(true)
    expect(mismoTotalDelAlta(100.01, 100)).toBe(true)
  })

  it('el mismo total es el mismo', () => {
    expect(mismoTotalDelAlta(1234.56, 1234.56)).toBe(true)
  })

  it('dos centavos ya no', () => {
    expect(mismoTotalDelAlta(99.98, 100)).toBe(false)
    expect(mismoTotalDelAlta(100.02, 100)).toBe(false)
  })
})

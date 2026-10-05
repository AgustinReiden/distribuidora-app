import { describe, it, expect } from 'vitest'
// @ts-expect-error -- módulo .mjs de scripts/, sin tipos
import { igual } from '../../scripts/lib/igualMonto.mjs'

/** Comparador de montos del gate `scripts/check-integridad.mjs` (#904). */
describe('igual (gate de integridad)', () => {
  it('tolera el error de punto flotante de x.62 por una cantidad entera', () => {
    const recalculado = 643.62 * 3 // 1930.86 exacto en numeric, 1930.8600000000001 en double
    expect(recalculado === 1930.86).toBe(false)
    expect(igual(recalculado, 1930.86)).toBe(true)
    expect(igual(103.62 * 11, '1139.82')).toBe(true)
  })

  it('acepta numeric como string', () => {
    expect(igual('643210.62', 643210.62)).toBe(true)
  })

  it('null sólo iguala a null', () => {
    expect(igual(null, null)).toBe(true)
    expect(igual(undefined, null)).toBe(true)
    expect(igual(null, 0)).toBe(false)
    expect(igual(5, null)).toBe(false)
  })

  it('una diferencia real de 0,01 sigue fallando', () => {
    expect(igual(643210.62, 643210.63)).toBe(false)
    expect(igual(643.62 * 3, 1930.87)).toBe(false)
  })
})

import { describe, it, expect } from 'vitest'
import { CATALOGO_VIEJO_MS, catalogoDebeRelerse } from './catalogoDeVenta'

describe('catalogoDebeRelerse (INF-1)', () => {
  const ahora = 1_800_000_000_000

  it('relee una copia de más de un minuto', () => {
    expect(catalogoDebeRelerse(ahora - CATALOGO_VIEJO_MS - 1, ahora)).toBe(true)
    expect(catalogoDebeRelerse(ahora - 10 * 60 * 1000, ahora)).toBe(true)
  })

  it('no relee una copia reciente', () => {
    expect(catalogoDebeRelerse(ahora - 5000, ahora)).toBe(false)
    expect(catalogoDebeRelerse(ahora - CATALOGO_VIEJO_MS, ahora)).toBe(false)
  })

  it('no relee si todavía no hay copia (carga en curso) o no se sabe', () => {
    expect(catalogoDebeRelerse(0, ahora)).toBe(false)
    expect(catalogoDebeRelerse(undefined, ahora)).toBe(false)
  })
})

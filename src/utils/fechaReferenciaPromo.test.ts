import { describe, it, expect } from 'vitest'
import { fechaReferenciaPromo } from './fechaReferenciaPromo'
import { fechaLocalISO } from './formatters'

describe('fechaReferenciaPromo (#1152: LEAST(fecha del pedido, hoy))', () => {
  const hoy = '2026-10-14'

  it('sin fecha da undefined (las promos de hoy)', () => {
    expect(fechaReferenciaPromo(undefined, hoy)).toBeUndefined()
    expect(fechaReferenciaPromo(null, hoy)).toBeUndefined()
    expect(fechaReferenciaPromo('', hoy)).toBeUndefined()
  })

  it('hoy da undefined: el queryKey sigue siendo el de hoy', () => {
    expect(fechaReferenciaPromo('2026-10-14', hoy)).toBeUndefined()
  })

  it('una fecha futura se topa a hoy (undefined)', () => {
    expect(fechaReferenciaPromo('2026-10-17', hoy)).toBeUndefined()
    expect(fechaReferenciaPromo('2027-01-01', hoy)).toBeUndefined()
  })

  it('una fecha pasada se usa tal cual', () => {
    expect(fechaReferenciaPromo('2026-10-12', hoy)).toBe('2026-10-12')
    expect(fechaReferenciaPromo('2026-04-06', hoy)).toBe('2026-04-06')
  })

  it('un timestamp se recorta a YYYY-MM-DD', () => {
    expect(fechaReferenciaPromo('2026-10-12T15:30:00-03:00', hoy)).toBe('2026-10-12')
    expect(fechaReferenciaPromo('2026-10-14T00:00:00Z', hoy)).toBeUndefined()
  })

  it('sin hoy inyectado usa la fecha argentina', () => {
    expect(fechaReferenciaPromo(fechaLocalISO())).toBeUndefined()
    expect(fechaReferenciaPromo('2000-01-01')).toBe('2000-01-01')
  })
})

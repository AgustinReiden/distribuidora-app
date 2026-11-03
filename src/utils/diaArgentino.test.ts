import { describe, expect, it } from 'vitest'
import { diaArgentino } from './formatters'

// #1344: el día de una entrega es el argentino, el que corta el server.
describe('diaArgentino', () => {
  it('una entrega del lunes a las 22:30 es del lunes, aunque en UTC ya sea martes', () => {
    expect(diaArgentino('2026-11-03T01:30:00+00:00')).toBe('2026-11-02')
  })

  it('a la medianoche argentina ya es el día siguiente', () => {
    expect(diaArgentino('2026-11-03T02:59:59+00:00')).toBe('2026-11-02')
    expect(diaArgentino('2026-11-03T03:00:00+00:00')).toBe('2026-11-03')
  })

  it('con offset argentino da el mismo día', () => {
    expect(diaArgentino('2026-11-02T12:00:00-03:00')).toBe('2026-11-02')
  })

  it('un valor que no es fecha no tira: cae al corte en la T', () => {
    expect(diaArgentino('no-es-fecha')).toBe('no-es-fecha')
  })
})

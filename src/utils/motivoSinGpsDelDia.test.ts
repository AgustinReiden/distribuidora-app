import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { motivoSinGpsDeHoy, recordarMotivoSinGps } from './motivoSinGpsDelDia'

describe('el motivo de ubicación bloqueada, una vez por día', () => {
  beforeEach(() => {
    localStorage.clear()
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-11-16T15:00:00Z'))
  })
  afterEach(() => vi.useRealTimers())

  it('sin nada guardado no hay motivo', () => {
    expect(motivoSinGpsDeHoy('denied')).toBeNull()
  })

  it('el motivo del primer pedido sirve para los demás del día', () => {
    recordarMotivoSinGps('denied', '  no me deja activarla ')
    expect(motivoSinGpsDeHoy('denied')).toBe('no me deja activarla')
  })

  it('al día siguiente se vuelve a pedir', () => {
    recordarMotivoSinGps('denied', 'no me deja activarla')
    vi.setSystemTime(new Date('2026-11-17T15:00:00Z'))
    expect(motivoSinGpsDeHoy('denied')).toBeNull()
  })

  it('el día es el argentino: a las 22 de Argentina sigue siendo hoy', () => {
    recordarMotivoSinGps('denied', 'no me deja activarla')
    vi.setSystemTime(new Date('2026-11-17T01:00:00Z'))
    expect(motivoSinGpsDeHoy('denied')).toBe('no me deja activarla')
  })

  it('sólo vale para la ubicación bloqueada: un timeout se justifica cada vez', () => {
    recordarMotivoSinGps('denied', 'no me deja activarla')
    expect(motivoSinGpsDeHoy('timeout')).toBeNull()
    recordarMotivoSinGps('timeout', 'sótano')
    expect(motivoSinGpsDeHoy('denied')).toBe('no me deja activarla')
  })

  it('un guardado roto no rompe ni inventa un motivo', () => {
    localStorage.setItem('gps.motivo_denied', '{no es json')
    expect(motivoSinGpsDeHoy('denied')).toBeNull()
  })
})

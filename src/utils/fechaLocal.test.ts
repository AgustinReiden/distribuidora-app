import { describe, it, expect, vi, afterEach } from 'vitest'
import { ymdLocal, ymdLocalDate, ultimoDiaDelMes, primerDiaMesAtras, hoyArgentinaLocal } from './fechaLocal'

describe('ymdLocal', () => {
  it('formatea con padding de mes y día', () => {
    expect(ymdLocal(2026, 0, 5)).toBe('2026-01-05')
    expect(ymdLocal(2026, 11, 31)).toBe('2026-12-31')
  })
})

describe('ymdLocalDate', () => {
  it('lee los componentes locales del Date, no toISOString', () => {
    // 00:30 local del 20/08: toISOString() en UTC-3 daría igual el 20, pero
    // en zonas al este de UTC correría al 19. Acá siempre gana el reloj local.
    expect(ymdLocalDate(new Date(2026, 7, 20, 0, 30))).toBe('2026-08-20')
  })
})

describe('ultimoDiaDelMes', () => {
  it('resuelve diciembre sin desbordar el año', () => {
    expect(ultimoDiaDelMes(2026, 11)).toBe(31)
  })

  it('febrero bisiesto vs no bisiesto', () => {
    expect(ultimoDiaDelMes(2028, 1)).toBe(29)
    expect(ultimoDiaDelMes(2027, 1)).toBe(28)
  })
})

describe('primerDiaMesAtras', () => {
  it('0 meses atrás es el primero del mes de base', () => {
    const d = primerDiaMesAtras(new Date(2026, 7, 20), 0)
    expect([d.getFullYear(), d.getMonth(), d.getDate()]).toEqual([2026, 7, 1])
  })

  it('cruza el año hacia atrás sin romperse', () => {
    const d = primerDiaMesAtras(new Date(2026, 0, 15), 1)
    expect([d.getFullYear(), d.getMonth(), d.getDate()]).toEqual([2025, 11, 1])
  })
})

describe('hoyArgentinaLocal (REP-9)', () => {
  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllEnvs()
  })

  // 01:30 UTC del 01/11 son las 22:30 del 31/10 en Argentina.
  it.each(['UTC', 'America/Argentina/Buenos_Aires', 'Asia/Tokyo'])(
    'a las 22:30 del 31/10 argentino sigue siendo el 31/10 (TZ del dispositivo: %s)',
    (tz) => {
      vi.stubEnv('TZ', tz)
      vi.useFakeTimers()
      vi.setSystemTime(new Date('2026-11-01T01:30:00Z'))
      const hoy = hoyArgentinaLocal()
      expect(ymdLocalDate(hoy)).toBe('2026-10-31')
      expect(hoy.getMonth()).toBe(9)
      expect(hoy.getDate()).toBe(31)
    },
  )

  it('la aritmética de calendario sigue igual (restar un mes, fin de mes)', () => {
    vi.stubEnv('TZ', 'UTC')
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-11-01T01:30:00Z'))
    const hoy = hoyArgentinaLocal()
    expect(ymdLocalDate(primerDiaMesAtras(hoy, 1))).toBe('2026-09-01')
    expect(ultimoDiaDelMes(hoy.getFullYear(), hoy.getMonth())).toBe(31)
  })
})

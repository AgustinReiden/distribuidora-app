/**
 * infra-INF-2 (tanda 6 de #1603): las fechas de «hace N días» y los atajos de Análisis salen del día
 * ARGENTINO, no del huso ni del cambio de horario del dispositivo.
 */
import { describe, it, expect, afterEach, vi } from 'vitest'
import { fechaHaceDias, sumarDiasAFechaISO } from './formatters'
import { rangoPresetAnalytics } from './rangoPresetAnalytics'

function enHuso(tz: string): void {
  vi.stubEnv('TZ', tz)
}

afterEach(() => {
  vi.unstubAllEnvs()
})

describe('sumarDiasAFechaISO', () => {
  it('suma y resta de calendario, con cruce de mes y de año', () => {
    expect(sumarDiasAFechaISO('2026-05-11', -30)).toBe('2026-04-11')
    expect(sumarDiasAFechaISO('2026-01-05', -10)).toBe('2025-12-26')
    expect(sumarDiasAFechaISO('2026-02-27', 3)).toBe('2026-03-02')
  })
})

describe('fechaHaceDias no depende del huso del dispositivo', () => {
  // 23:30 del 6 de abril en Argentina. En Nueva York (con cambio de horario el 8 de marzo)
  // restar 30 días con setDate dejaba la hora local y corría el instante una hora: caía el 8.
  const base = new Date('2026-04-07T02:30:00Z')

  it.each(['America/New_York', 'UTC', 'Pacific/Kiritimati', 'America/Argentina/Buenos_Aires'])('en %s', (tz) => {
    enHuso(tz)
    expect(fechaHaceDias(30, base)).toBe('2026-03-07')
    expect(fechaHaceDias(0, base)).toBe('2026-04-06')
  })
})

describe('rangoPresetAnalytics', () => {
  // Mediodía argentino del 24/11/2026.
  const ahora = new Date('2026-11-24T15:00:00Z')

  it.each(['UTC', 'Pacific/Kiritimati', 'America/Argentina/Buenos_Aires', 'America/Los_Angeles'])('en %s da el mismo rango', (tz) => {
    enHuso(tz)
    expect(rangoPresetAnalytics('ultimo_mes', ahora)).toEqual({ desde: '2026-10-24', hasta: '2026-11-24' })
    expect(rangoPresetAnalytics('ultimos_3_meses', ahora)).toEqual({ desde: '2026-08-24', hasta: '2026-11-24' })
    expect(rangoPresetAnalytics('este_ano', ahora)).toEqual({ desde: '2026-01-01', hasta: '2026-11-24' })
  })

  it('a la noche argentina usa el día argentino, no el del dispositivo (01:00Z del 25 es el 24 a las 22 hs)', () => {
    enHuso('UTC')
    expect(rangoPresetAnalytics('ultimo_mes', new Date('2026-11-25T01:00:00Z'))).toEqual({ desde: '2026-10-24', hasta: '2026-11-24' })
  })

  it('el día 31 sigue el rollover de siempre: 31 de marzo menos un mes es 3 de marzo', () => {
    expect(rangoPresetAnalytics('ultimo_mes', new Date('2026-03-31T15:00:00Z')).desde).toBe('2026-03-03')
  })
})

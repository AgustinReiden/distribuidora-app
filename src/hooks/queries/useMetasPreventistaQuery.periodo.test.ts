/** REP-9: el período por defecto de las metas es el mes del día argentino, no el del dispositivo. */
import { describe, it, expect, vi, afterEach } from 'vitest'

vi.mock('../supabase/base', () => ({ supabase: { rpc: vi.fn(), from: vi.fn() } }))
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))

import { periodoMensual } from './useMetasPreventistaQuery'

describe('periodoMensual', () => {
  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllEnvs()
  })

  it('a las 22:30 del 31/10 argentino (dispositivo en UTC) sigue siendo octubre', () => {
    vi.stubEnv('TZ', 'UTC')
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-11-01T01:30:00Z'))
    expect(periodoMensual()).toBe('2026-10-01')
  })

  it('con una fecha explícita no la corre', () => {
    expect(periodoMensual(new Date(2026, 10, 15))).toBe('2026-11-01')
  })
})

/**
 * Tests del hook `useGeolocationCapture`.
 *
 * Mockean `navigator.geolocation` para verificar los 4 escenarios:
 *   - ok (happy path)
 *   - denied (usuario rechaza el prompt)
 *   - timeout (sin señal)
 *   - unavailable (POSITION_UNAVAILABLE / sin API)
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useGeolocationCapture } from './useGeolocationCapture'

// Constantes equivalentes a `PositionError`
const PERMISSION_DENIED = 1
const POSITION_UNAVAILABLE = 2
const TIMEOUT = 3

interface MockGeolocation {
  getCurrentPosition: ReturnType<typeof vi.fn>
}

function setGeolocation(mock: MockGeolocation | null) {
  if (mock === null) {
    // Simular ausencia total de la API
    // @ts-expect-error - intentionally unsetting
    delete (navigator as Navigator).geolocation
    return
  }
  Object.defineProperty(navigator, 'geolocation', {
    value: mock,
    configurable: true,
    writable: true,
  })
}

describe('useGeolocationCapture', () => {
  const originalGeolocation = (navigator as Navigator).geolocation

  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
    // Restore original geolocation if it existed
    if (originalGeolocation !== undefined) {
      Object.defineProperty(navigator, 'geolocation', {
        value: originalGeolocation,
        configurable: true,
        writable: true,
      })
    }
  })

  it('returns ok with coordinates when permission is granted', async () => {
    setGeolocation({
      getCurrentPosition: vi.fn((success: (pos: GeolocationPosition) => void) => {
        success({
          coords: {
            latitude: -26.81,
            longitude: -65.22,
            accuracy: 18,
            altitude: null,
            altitudeAccuracy: null,
            heading: null,
            speed: null,
          },
          timestamp: Date.now(),
        } as GeolocationPosition)
      }),
    })

    const { result } = renderHook(() => useGeolocationCapture())
    const gps = await act(() => result.current())

    expect(gps.status).toBe('ok')
    if (gps.status === 'ok') {
      expect(gps.lat).toBeCloseTo(-26.81)
      expect(gps.lng).toBeCloseTo(-65.22)
      expect(gps.accuracy).toBe(18)
      expect(gps.capturadoAt).toMatch(/^\d{4}-\d{2}-\d{2}T/)
    }
  })

  it('returns denied when user rejects the permission prompt', async () => {
    setGeolocation({
      getCurrentPosition: vi.fn((_success, error) => {
        error?.({ code: PERMISSION_DENIED, PERMISSION_DENIED, POSITION_UNAVAILABLE, TIMEOUT, message: 'User denied' } as GeolocationPositionError)
      }),
    })

    const { result } = renderHook(() => useGeolocationCapture())
    const gps = await act(() => result.current())

    expect(gps.status).toBe('denied')
  })

  it('returns timeout when the browser does not respond in time', async () => {
    setGeolocation({
      getCurrentPosition: vi.fn((_success, error) => {
        error?.({ code: TIMEOUT, PERMISSION_DENIED, POSITION_UNAVAILABLE, TIMEOUT, message: 'Timeout' } as GeolocationPositionError)
      }),
    })

    const { result } = renderHook(() => useGeolocationCapture())
    const gps = await act(() => result.current())

    expect(gps.status).toBe('timeout')
  })

  it('returns unavailable when POSITION_UNAVAILABLE is reported', async () => {
    setGeolocation({
      getCurrentPosition: vi.fn((_success, error) => {
        error?.({ code: POSITION_UNAVAILABLE, PERMISSION_DENIED, POSITION_UNAVAILABLE, TIMEOUT, message: 'Unavailable' } as GeolocationPositionError)
      }),
    })

    const { result } = renderHook(() => useGeolocationCapture())
    const gps = await act(() => result.current())

    expect(gps.status).toBe('unavailable')
  })

  it('returns unavailable when navigator.geolocation is missing', async () => {
    setGeolocation(null)

    const { result } = renderHook(() => useGeolocationCapture())
    const gps = await act(() => result.current())

    expect(gps.status).toBe('unavailable')
  })

  it('never rejects when the underlying call throws', async () => {
    setGeolocation({
      getCurrentPosition: vi.fn(() => {
        throw new Error('boom')
      }),
    })

    const { result } = renderHook(() => useGeolocationCapture())
    await expect(act(() => result.current())).resolves.toMatchObject({ status: 'error' })
  })
})

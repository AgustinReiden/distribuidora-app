import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useDiaArgentino } from './useDiaArgentino'

describe('useDiaArgentino (1597-b3)', () => {
  beforeEach(() => {
    // 23:59:30 del 30/11 en Argentina = 02:59:30 UTC del 01/12.
    vi.useFakeTimers({ toFake: ['Date', 'setInterval', 'clearInterval'], now: new Date('2026-12-01T02:59:30Z') })
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('arranca con el día argentino, no el UTC', () => {
    const { result } = renderHook(() => useDiaArgentino())
    expect(result.current).toBe('2026-11-30')
  })

  it('pasa al día nuevo al cruzar la medianoche', () => {
    const { result } = renderHook(() => useDiaArgentino())

    act(() => { vi.advanceTimersByTime(60_000) })

    expect(result.current).toBe('2026-12-01')
  })

  it('al volver a la pestaña (los temporizadores estaban frenados) se actualiza sin esperar el intervalo', () => {
    const { result } = renderHook(() => useDiaArgentino())
    // El reloj avanza mientras la pestaña estaba en segundo plano: ningún intervalo corrió.
    vi.setSystemTime(new Date('2026-12-01T10:00:00Z'))
    expect(result.current).toBe('2026-11-30')

    act(() => { document.dispatchEvent(new Event('visibilitychange')) })

    expect(result.current).toBe('2026-12-01')
  })

  it('limpia el intervalo y el listener al desmontar', () => {
    const quitar = vi.spyOn(document, 'removeEventListener')
    const { unmount } = renderHook(() => useDiaArgentino())

    unmount()

    expect(quitar).toHaveBeenCalledWith('visibilitychange', expect.any(Function))
    quitar.mockRestore()
  })
})

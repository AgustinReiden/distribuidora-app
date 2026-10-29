/**
 * Supabase vuelve a unir el canal solo tras un corte (realtime-js reenvía el
 * join y vuelve a llamar al callback de `subscribe` con SUBSCRIBED), pero lo
 * que cambió mientras estuvo caído no llega como evento. Sin `onReconnect`
 * nadie invalidaba nada y la pantalla seguía con el stock de antes del corte
 * hasta cumplir el staleTime (#1265). Y `TIMED_OUT` no se mapeaba.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'

type CallbackEstado = (estado: string) => void
const callbacks: CallbackEstado[] = []

vi.mock('../lib/supabase', () => ({
  supabase: {
    channel: vi.fn(() => {
      const canal = {
        on: vi.fn(() => canal),
        subscribe: vi.fn((cb: CallbackEstado) => {
          callbacks.push(cb)
          return canal
        }),
      }
      return canal
    }),
    removeChannel: vi.fn(),
  },
}))

import { useRealtimeSubscription } from './useRealtimeSubscription'

describe('useRealtimeSubscription', () => {
  beforeEach(() => {
    callbacks.length = 0
  })

  it('no llama a onReconnect en la primera suscripción', () => {
    const onReconnect = vi.fn()
    const { result } = renderHook(() =>
      useRealtimeSubscription({ table: 'productos', onEvent: vi.fn(), onReconnect }),
    )

    act(() => callbacks[0]('SUBSCRIBED'))

    expect(result.current.status).toBe('SUBSCRIBED')
    expect(onReconnect).not.toHaveBeenCalled()
  })

  it('mapea TIMED_OUT y llama a onReconnect cuando el canal vuelve', () => {
    const onReconnect = vi.fn()
    const { result } = renderHook(() =>
      useRealtimeSubscription({ table: 'productos', onEvent: vi.fn(), onReconnect }),
    )

    act(() => callbacks[0]('SUBSCRIBED'))
    act(() => callbacks[0]('TIMED_OUT'))
    expect(result.current.status).toBe('TIMED_OUT')

    act(() => callbacks[0]('SUBSCRIBED'))
    expect(result.current.status).toBe('SUBSCRIBED')
    expect(onReconnect).toHaveBeenCalledTimes(1)
  })

  it('después de CHANNEL_ERROR la vuelta también avisa', () => {
    const onReconnect = vi.fn()
    renderHook(() =>
      useRealtimeSubscription({ table: 'pedidos', onEvent: vi.fn(), onReconnect }),
    )

    act(() => callbacks[0]('SUBSCRIBED'))
    act(() => callbacks[0]('CHANNEL_ERROR'))
    act(() => callbacks[0]('SUBSCRIBED'))

    expect(onReconnect).toHaveBeenCalledTimes(1)
  })

  it('el canal nuevo tras volver la red (enabled false → true) cuenta como vuelta', () => {
    const onReconnect = vi.fn()
    const { rerender } = renderHook(
      ({ enabled }) => useRealtimeSubscription({ table: 'pedidos', onEvent: vi.fn(), onReconnect, enabled }),
      { initialProps: { enabled: true } },
    )

    act(() => callbacks[0]('SUBSCRIBED'))
    rerender({ enabled: false })
    rerender({ enabled: true })
    act(() => callbacks[1]('SUBSCRIBED'))

    expect(onReconnect).toHaveBeenCalledTimes(1)
  })
})

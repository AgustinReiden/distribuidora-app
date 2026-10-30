import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

// Stub Supabase clients — the hook files transitively import them, but we
// never actually hit the network in these tests.
vi.mock('../lib/supabase', () => ({
  supabase: {
    channel: vi.fn(),
    removeChannel: vi.fn(),
    from: vi.fn(),
    rpc: vi.fn(),
  },
  setSucursalHeader: vi.fn(),
}))

vi.mock('./supabase/base', () => ({
  supabase: {
    channel: vi.fn(),
    removeChannel: vi.fn(),
    from: vi.fn(),
    rpc: vi.fn(),
  },
}))

// Mock useRealtimeSubscription — no real subscription, just a stub that
// captures the onEvent callback so we can simulate payloads from the test.
const subscriptionCallbacks: Record<string, (payload: unknown) => void> = {}
const reconnectCallbacks: Record<string, (() => void) | undefined> = {}

vi.mock('./useRealtimeSubscription', () => ({
  useRealtimeSubscription: ({
    table,
    onEvent,
    onReconnect,
  }: {
    table: string
    event?: string
    onEvent: (payload: unknown) => void
    onReconnect?: () => void
    enabled?: boolean
  }) => {
    subscriptionCallbacks[table] = onEvent
    reconnectCallbacks[table] = onReconnect
    return { status: 'SUBSCRIBED' as const, unsubscribe: vi.fn() }
  },
}))

// Mock SucursalContext to return a fixed sucursalId
vi.mock('../contexts/SucursalContext', () => ({
  useSucursal: () => ({
    currentSucursalId: 1,
    currentSucursalNombre: 'Test',
    currentSucursalRol: 'admin',
    currentSucursalRolesExtra: [],
    sucursales: [],
    loading: false,
    hasMultipleSucursales: false,
    switchSucursal: vi.fn(),
  }),
}))

// Import after mocks
import { useRealtimeInvalidation } from './useRealtimeInvalidation'
import { pedidosKeys } from './queries/usePedidosQuery'
import { productosKeys } from './queries/useProductosQuery'

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

/**
 * `pedidosKeys.lists()` y `.detail()` son keys que ninguna query lee — la
 * pantalla de pedidos usa `paginated` y `stats`, ambas hijas de `.all()` —
 * así que invalidarlas no refrescaba nada ante un cambio realtime de otro
 * usuario (#524). Estos tests fijan que TODO evento de pedidos invalida
 * `pedidosKeys.all()`, que sí cubre esas dos.
 */
describe('useRealtimeInvalidation', () => {
  beforeEach(() => {
    for (const k of Object.keys(subscriptionCallbacks)) {
      delete subscriptionCallbacks[k]
    }
  })

  /**
   * Lo que cambió mientras el canal estuvo caído no llega como evento (#1265):
   * al volver hay que invalidar lo que cada canal cubría.
   */
  it('al reconectar invalida pedidos y productos', async () => {
    const qc = new QueryClient()
    const spy = vi.spyOn(qc, 'invalidateQueries')
    renderHook(() => useRealtimeInvalidation({ debounceMs: 0 }), {
      wrapper: makeWrapper(qc),
    })

    await act(async () => {
      reconnectCallbacks['pedidos']?.()
      reconnectCallbacks['pedido_items']?.()
      reconnectCallbacks['productos']?.()
      await new Promise(r => setTimeout(r, 20))
    })

    expect(spy).toHaveBeenCalledWith({ queryKey: pedidosKeys.all(1) })
    expect(spy).toHaveBeenCalledWith({ queryKey: productosKeys.all(1) })
  })

  it('invalida pedidosKeys.all() cuando se llama invalidatePedido(id)', async () => {
    const qc = new QueryClient()
    const spy = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(
      () => useRealtimeInvalidation({ debounceMs: 0 }),
      { wrapper: makeWrapper(qc) }
    )

    await act(async () => {
      result.current.invalidatePedido('42')
      await new Promise(r => setTimeout(r, 20))
    })

    expect(spy).toHaveBeenCalledWith({
      queryKey: pedidosKeys.all(1),
    })
  })

  it('invalida pedidosKeys.all() con invalidatePedidosList()', async () => {
    const qc = new QueryClient()
    const spy = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(
      () => useRealtimeInvalidation({ debounceMs: 0 }),
      { wrapper: makeWrapper(qc) }
    )

    await act(async () => {
      result.current.invalidatePedidosList()
      await new Promise(r => setTimeout(r, 20))
    })

    expect(spy).toHaveBeenCalledWith({
      queryKey: pedidosKeys.all(1),
    })
  })

  it('invalida productos con invalidateProductos()', async () => {
    const qc = new QueryClient()
    const spy = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(
      () => useRealtimeInvalidation({ debounceMs: 0 }),
      { wrapper: makeWrapper(qc) }
    )

    await act(async () => {
      result.current.invalidateProductos()
      await new Promise(r => setTimeout(r, 20))
    })

    expect(spy).toHaveBeenCalledWith({
      queryKey: productosKeys.all(1),
    })
  })

  it('debounces multiple invalidatePedido calls to the same id', async () => {
    const qc = new QueryClient()
    const spy = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(
      () => useRealtimeInvalidation({ debounceMs: 50 }),
      { wrapper: makeWrapper(qc) }
    )

    await act(async () => {
      result.current.invalidatePedido('42')
      result.current.invalidatePedido('42')
      result.current.invalidatePedido('42')
      await new Promise(r => setTimeout(r, 100))
    })

    const llamadasAll = spy.mock.calls.filter(
      c =>
        JSON.stringify((c[0] as { queryKey: unknown }).queryKey) ===
        JSON.stringify(pedidosKeys.all(1))
    )
    expect(llamadasAll.length).toBe(1)
  })

  /**
   * Armar un reparto cambia decenas de pedidos en un segundo, y llega un UPDATE
   * por cada uno. Con un debounce por pedido, 44 pedidos eran 44 recargas de
   * todo `pedidosKeys.all()` en cada pantalla abierta: ~180 consultas en 5 s y
   * la lista tardando 5 s en producción.
   */
  it('una ráfaga de UPDATEs de pedidos distintos invalida una sola vez', async () => {
    const qc = new QueryClient()
    const spy = vi.spyOn(qc, 'invalidateQueries')
    renderHook(() => useRealtimeInvalidation({ debounceMs: 50 }), {
      wrapper: makeWrapper(qc),
    })

    await act(async () => {
      for (let id = 1; id <= 44; id++) {
        subscriptionCallbacks['pedidos']({
          eventType: 'UPDATE',
          new: { id, estado: 'asignado' },
        })
      }
      subscriptionCallbacks['pedido_items']({
        eventType: 'UPDATE',
        new: { id: 1, pedido_id: 500, cantidad: 2 },
      })
      await new Promise(r => setTimeout(r, 100))
    })

    const llamadasAll = spy.mock.calls.filter(
      c =>
        JSON.stringify((c[0] as { queryKey: unknown }).queryKey) ===
        JSON.stringify(pedidosKeys.all(1))
    )
    expect(llamadasAll.length).toBe(1)
  })

  it('INSERT en pedidos dispara invalidación de pedidosKeys.all()', async () => {
    const qc = new QueryClient()
    const spy = vi.spyOn(qc, 'invalidateQueries')
    renderHook(() => useRealtimeInvalidation({ debounceMs: 0 }), {
      wrapper: makeWrapper(qc),
    })

    await act(async () => {
      subscriptionCallbacks['pedidos']({
        eventType: 'INSERT',
        new: { id: 99 },
      })
      await new Promise(r => setTimeout(r, 20))
    })

    expect(spy).toHaveBeenCalledWith({
      queryKey: pedidosKeys.all(1),
    })
  })

  it('UPDATE en pedidos dispara invalidación de pedidosKeys.all()', async () => {
    const qc = new QueryClient()
    const spy = vi.spyOn(qc, 'invalidateQueries')
    renderHook(() => useRealtimeInvalidation({ debounceMs: 0 }), {
      wrapper: makeWrapper(qc),
    })

    await act(async () => {
      subscriptionCallbacks['pedidos']({
        eventType: 'UPDATE',
        new: { id: 7, estado: 'entregado' },
      })
      await new Promise(r => setTimeout(r, 20))
    })

    expect(spy).toHaveBeenCalledWith({
      queryKey: pedidosKeys.all(1),
    })
  })

  it('DELETE en pedidos invalida pedidosKeys.all()', async () => {
    const qc = new QueryClient()
    const spy = vi.spyOn(qc, 'invalidateQueries')
    renderHook(() => useRealtimeInvalidation({ debounceMs: 0 }), {
      wrapper: makeWrapper(qc),
    })

    await act(async () => {
      subscriptionCallbacks['pedidos']({
        eventType: 'DELETE',
        old: { id: 13 },
      })
      await new Promise(r => setTimeout(r, 20))
    })

    expect(spy).toHaveBeenCalledWith({
      queryKey: pedidosKeys.all(1),
    })
  })

  it('cambio en pedido_items invalida pedidosKeys.all()', async () => {
    const qc = new QueryClient()
    const spy = vi.spyOn(qc, 'invalidateQueries')
    renderHook(() => useRealtimeInvalidation({ debounceMs: 0 }), {
      wrapper: makeWrapper(qc),
    })

    await act(async () => {
      subscriptionCallbacks['pedido_items']({
        eventType: 'UPDATE',
        new: { id: 1, pedido_id: 500, cantidad: 2 },
      })
      await new Promise(r => setTimeout(r, 20))
    })

    expect(spy).toHaveBeenCalledWith({
      queryKey: pedidosKeys.all(1),
    })
  })
})

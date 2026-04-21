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

vi.mock('./useRealtimeSubscription', () => ({
  useRealtimeSubscription: ({
    table,
    onEvent,
  }: {
    table: string
    event?: string
    onEvent: (payload: unknown) => void
    enabled?: boolean
  }) => {
    subscriptionCallbacks[table] = onEvent
    return { status: 'SUBSCRIBED' as const, unsubscribe: vi.fn() }
  },
}))

// Mock SucursalContext to return a fixed sucursalId
vi.mock('../contexts/SucursalContext', () => ({
  useSucursal: () => ({
    currentSucursalId: 1,
    currentSucursalNombre: 'Test',
    currentSucursalRol: 'admin',
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

describe('useRealtimeInvalidation', () => {
  beforeEach(() => {
    for (const k of Object.keys(subscriptionCallbacks)) {
      delete subscriptionCallbacks[k]
    }
  })

  it('invalida solo el detail cuando se llama invalidatePedido(id)', async () => {
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
      queryKey: pedidosKeys.detail(1, '42'),
    })
    // NO debe invalidar la lista completa
    expect(spy).not.toHaveBeenCalledWith({
      queryKey: pedidosKeys.lists(1),
    })
  })

  it('invalida toda la lista con invalidatePedidosList()', async () => {
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
      queryKey: pedidosKeys.lists(1),
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

    const detailCalls = spy.mock.calls.filter(
      c =>
        JSON.stringify((c[0] as { queryKey: unknown }).queryKey) ===
        JSON.stringify(pedidosKeys.detail(1, '42'))
    )
    expect(detailCalls.length).toBe(1)
  })

  it('INSERT en pedidos dispara invalidación de la lista (no del detail)', async () => {
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
      queryKey: pedidosKeys.lists(1),
    })
    expect(spy).not.toHaveBeenCalledWith({
      queryKey: pedidosKeys.detail(1, '99'),
    })
  })

  it('UPDATE en pedidos dispara invalidación solo del detail (no de la lista)', async () => {
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
      queryKey: pedidosKeys.detail(1, '7'),
    })
    expect(spy).not.toHaveBeenCalledWith({
      queryKey: pedidosKeys.lists(1),
    })
  })

  it('DELETE en pedidos invalida detail Y lista', async () => {
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
      queryKey: pedidosKeys.detail(1, '13'),
    })
    expect(spy).toHaveBeenCalledWith({
      queryKey: pedidosKeys.lists(1),
    })
  })

  it('cambio en pedido_items invalida el detail del pedido padre', async () => {
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
      queryKey: pedidosKeys.detail(1, '500'),
    })
  })
})

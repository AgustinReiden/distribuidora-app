/**
 * 1600-b3: la lista de pedidos conserva lo anterior al cambiar de página o de filtro, pero NO al
 * cambiar de sucursal.
 *
 * `placeholderData: keepPreviousData` mostraba, unos segundos tras cambiar de sucursal, los
 * pedidos de la sucursal anterior como si fueran los de la nueva.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const m = vi.hoisted(() => ({
  sucursal: 1,
  // Lo que contesta la base según la sucursal; `retener` deja la respuesta pendiente.
  retener: false,
  liberar: null as null | (() => void),
}))

vi.mock('../supabase/base', () => {
  const builder: Record<string, unknown> = {}
  const encadenar = () => builder
  for (const metodo of ['select', 'order', 'range', 'eq', 'neq', 'in', 'gte', 'lte', 'or', 'is', 'not', 'ilike']) {
    builder[metodo] = encadenar
  }
  builder.then = (resolver: (v: unknown) => unknown, rechazar?: (e: unknown) => unknown) => {
    const respuesta = {
      data: [{ id: m.sucursal * 100, estado: 'pendiente', usuario_id: null, transportista_id: null, entregado_por: null }],
      error: null,
      count: 1,
    }
    const listo = m.retener
      ? new Promise<void>(res => { m.liberar = res }).then(() => respuesta)
      : Promise.resolve(respuesta)
    return listo.then(resolver, rechazar)
  }
  return { supabase: { from: () => builder, rpc: vi.fn() } }
})

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: m.sucursal }),
}))

import { usePedidosPaginatedQuery } from './usePedidosQuery'

function montar() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return renderHook(
    ({ page }: { page: number }) => usePedidosPaginatedQuery(page, 20),
    { wrapper, initialProps: { page: 1 } },
  )
}

const idsDe = (data: { data?: Array<{ id: unknown }> } | undefined) => data?.data?.map(p => Number(p.id))

beforeEach(() => {
  m.sucursal = 1
  m.retener = false
  m.liberar = null
})

describe('usePedidosPaginatedQuery — placeholder (1600-b3)', () => {
  it('al cambiar de sucursal no muestra los pedidos de la anterior mientras carga', async () => {
    const hook = montar()
    await waitFor(() => expect(idsDe(hook.result.current.data)).toEqual([100]))

    m.sucursal = 2
    m.retener = true
    m.liberar = null
    hook.rerender({ page: 1 })

    expect(hook.result.current.data).toBeUndefined()
    expect(hook.result.current.isPlaceholderData).toBe(false)

    await waitFor(() => expect(m.liberar).not.toBeNull())
    await act(async () => { m.liberar?.() })
    await waitFor(() => expect(idsDe(hook.result.current.data)).toEqual([200]))
  })

  it('al cambiar de página en la MISMA sucursal sí conserva la anterior (sin parpadeo)', async () => {
    const hook = montar()
    await waitFor(() => expect(idsDe(hook.result.current.data)).toEqual([100]))

    m.retener = true
    m.liberar = null
    hook.rerender({ page: 2 })

    expect(idsDe(hook.result.current.data)).toEqual([100])
    expect(hook.result.current.isPlaceholderData).toBe(true)

    await waitFor(() => expect(m.liberar).not.toBeNull())
    await act(async () => { m.liberar?.() })
    await waitFor(() => expect(hook.result.current.isPlaceholderData).toBe(false))
  })
})

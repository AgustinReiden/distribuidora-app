/**
 * El filtro «Con salvedad / Sin salvedad» de la lista de pedidos (1598-b4, #1598).
 *
 * Antes la lista pedía primero los ids de todos los pedidos con salvedad vigente
 * (`salvedades_items`) y los mandaba en la URL (`id=in.(…)`): pasados 700 ids el filtro
 * dejaba de andar. Ahora filtra en el server por la columna calculada
 * `tiene_salvedad_vigente(pedidos)` (vigente = no anulada, #1180): un solo pedido de la
 * lista, sin ids en la URL, tenga la tabla las salvedades que tenga.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

interface Llamada { tabla: string; metodo: string; args: unknown[] }
const llamadas: Llamada[] = []

/** Builder de supabase-js: anota cada llamada y `await` devuelve una página vacía. */
function builderDe(tabla: string) {
  const proxy: unknown = new Proxy({}, {
    get: (_t, prop: string) => {
      if (prop === 'then') {
        return (resolve: (v: unknown) => unknown) => resolve({ data: [], error: null, count: 0 })
      }
      return (...args: unknown[]) => {
        llamadas.push({ tabla, metodo: prop, args })
        return proxy
      }
    },
  })
  return proxy
}

vi.mock('../supabase/base', () => ({
  supabase: { from: (tabla: string) => builderDe(tabla) },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { usePedidosPaginatedQuery } from './usePedidosQuery'

function montar(conSalvedad: 'todos' | 'con_salvedad' | 'sin_salvedad') {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderHook(() => usePedidosPaginatedQuery(1, 15, { conSalvedad }), {
    wrapper: ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    ),
  })
}

const sobrePedidos = (metodo: string) => llamadas.filter(l => l.tabla === 'pedidos' && l.metodo === metodo)

beforeEach(() => {
  llamadas.length = 0
})

describe('filtro con/sin salvedad de la lista de pedidos (1598-b4)', () => {
  it('«Con salvedad» filtra en el server por la marca, sin pedir ids a salvedades_items', async () => {
    const { result } = montar('con_salvedad')
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(sobrePedidos('eq')).toContainEqual({ tabla: 'pedidos', metodo: 'eq', args: ['tiene_salvedad_vigente', true] })
    // Ni la lista de ids en la URL, ni la vuelta previa a salvedades_items para armarla.
    expect(sobrePedidos('in').filter(l => l.args[0] === 'id')).toEqual([])
    expect(sobrePedidos('not').filter(l => l.args[0] === 'id')).toEqual([])
    expect(llamadas.filter(l => l.tabla === 'salvedades_items')).toEqual([])
  })

  it('«Sin salvedad» pide la marca en false', async () => {
    const { result } = montar('sin_salvedad')
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(sobrePedidos('eq')).toContainEqual({ tabla: 'pedidos', metodo: 'eq', args: ['tiene_salvedad_vigente', false] })
    expect(llamadas.filter(l => l.tabla === 'salvedades_items')).toEqual([])
  })

  it('«Todos» no filtra por la marca', async () => {
    const { result } = montar('todos')
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(sobrePedidos('eq').filter(l => l.args[0] === 'tiene_salvedad_vigente')).toEqual([])
  })
})

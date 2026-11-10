/**
 * La lista paginada de pedidos (#1517, FRT-8 y un menor).
 *
 * FRT-8: al enriquecer la página con los perfiles (vendedor y chofer) y las
 * salvedades, los errores se tragaban. La lista salía igual, sin vendedor y sin
 * ninguna salvedad: un pedido con faltante se veía como entregado completo. Ahora
 * el error sube y la pantalla muestra su "Reintentar" en vez de una lista que miente.
 *
 * Menor: `created_at` no es único (el replay de la cola y las altas masivas
 * comparten timestamp), así que `range()` sin desempate puede repetir un pedido
 * entre dos páginas y saltar otro. La consulta desempata por `id`.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

type Orden = { columna: string; opciones?: { ascending?: boolean } }
const ordenes: Orden[] = []
const resultados = {
  pedidos: { data: [] as unknown[], error: null as unknown, count: 0 },
  perfiles: { data: [] as unknown[], error: null as unknown },
  salvedades: { data: [] as unknown[], error: null as unknown },
}

/** Builder de supabase-js: cualquier método encadena y `await` devuelve el resultado fijado. */
function builderDe(clave: keyof typeof resultados) {
  const proxy: unknown = new Proxy({}, {
    get: (_t, prop: string) => {
      if (prop === 'then') {
        return (resolve: (v: unknown) => unknown) => resolve(resultados[clave])
      }
      if (prop === 'order') {
        return (columna: string, opciones?: { ascending?: boolean }) => {
          if (clave === 'pedidos') ordenes.push({ columna, opciones })
          return proxy
        }
      }
      return () => proxy
    },
  })
  return proxy
}

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (tabla: string) => {
      if (tabla === 'pedidos') return builderDe('pedidos')
      if (tabla === 'perfiles') return builderDe('perfiles')
      if (tabla === 'salvedades_items') return builderDe('salvedades')
      throw new Error(`tabla inesperada: ${tabla}`)
    },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { usePedidosPaginatedQuery } from './usePedidosQuery'

function montar() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderHook(() => usePedidosPaginatedQuery(1, 15), {
    wrapper: ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    ),
  })
}

const PEDIDO_ENTREGADO = {
  id: 10, estado: 'entregado', usuario_id: 'u1', transportista_id: 't1', total: 1000,
}

beforeEach(() => {
  ordenes.length = 0
  resultados.pedidos = { data: [PEDIDO_ENTREGADO], error: null, count: 1 }
  resultados.perfiles = { data: [{ id: 'u1', nombre: 'Ana', email: 'ana@x.com' }, { id: 't1', nombre: 'Beto', email: 'beto@x.com' }], error: null }
  resultados.salvedades = { data: [], error: null }
})

describe('usePedidosPaginatedQuery — enriquecimiento de la página (FRT-8)', () => {
  it('con todo bien, la página sale con el vendedor y el chofer', async () => {
    const { result } = montar()
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    const [pedido] = result.current.data!.data
    expect(pedido.usuario?.nombre).toBe('Ana')
    expect(pedido.transportista?.nombre).toBe('Beto')
  })

  it('si falla la consulta de perfiles, la lista falla (no sale sin vendedor)', async () => {
    resultados.perfiles = { data: [], error: { message: 'Failed to fetch' } }
    const { result } = montar()

    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(result.current.data).toBeUndefined()
  })

  it('si falla la consulta de salvedades, la lista falla (no sale como entregada completa)', async () => {
    resultados.salvedades = { data: [], error: { message: 'Failed to fetch' } }
    const { result } = montar()

    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(result.current.data).toBeUndefined()
  })
})

describe('usePedidosPaginatedQuery — orden estable entre páginas', () => {
  it('ordena por created_at desc y desempata por id desc', async () => {
    const { result } = montar()
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(ordenes).toEqual([
      { columna: 'created_at', opciones: { ascending: false } },
      { columna: 'id', opciones: { ascending: false } },
    ])
  })
})

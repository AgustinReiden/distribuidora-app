/**
 * Las cards de "Pedidos" truncaban en silencio (#524, mismo patrón que
 * useMetricasQuery.truncado.test.tsx pero del lado de la lista de pedidos).
 *
 * `fetchPedidoStats` pedía `range(0, 9999)` creyendo que el tope de PostgREST
 * era 10.000; en realidad corta en 1.000 y devuelve 200 igual, sin avisar. Con
 * la ventana por defecto (últimos 30 días, ~1.064 pedidos) las seis cards —
 * incluida "Impagos"— sumaban un subconjunto de ~1.000 sin que nada lo
 * indicara.
 *
 * Estos tests fijan que ahora pagina hasta agotar los pedidos (o hasta un
 * tope explícito, que se marca como `aproximado` en vez de mentir un total
 * completo).
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const from = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (...args: unknown[]) => from(...args),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { usePedidoStatsQuery } from './usePedidoStatsQuery'

/** El tope de PostgREST: corta en 1.000 filas por `.range()`, pase lo que pase. */
const TOPE_POSTGREST = 1000

/** Emula la tabla `pedidos` con `totalFilas` filas, repartidas entre estados. */
function tablaFake(totalFilas: number) {
  const filas = Array.from({ length: totalFilas }, (_, i) => ({
    id: i + 1,
    estado: (['pendiente', 'en_preparacion', 'asignado', 'entregado'] as const)[i % 4],
    estado_pago: i % 3 === 0 ? 'pagado' : 'pendiente',
    total: 100,
  }))

  const builder: Record<string, unknown> = {}
  const encadenable = () => builder
  builder.select = encadenable
  builder.order = encadenable
  builder.eq = encadenable
  builder.gte = encadenable
  builder.lte = encadenable
  builder.or = encadenable
  builder.in = encadenable
  builder.not = encadenable
  builder.range = (desde: number, hasta: number) => {
    const pedidas = hasta - desde + 1
    const cuantas = Math.min(pedidas, TOPE_POSTGREST)
    return Promise.resolve({ data: filas.slice(desde, desde + cuantas), error: null })
  }
  return builder
}

function nuevoQueryClient() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } })
}

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe('usePedidoStatsQuery — sin truncado silencioso (#524)', () => {
  it('con la ventana por defecto (~1.064 pedidos) las cards suman el total exacto, no los primeros 1.000', async () => {
    from.mockImplementation(() => tablaFake(1064))
    const qc = nuevoQueryClient()
    const { result } = renderHook(() => usePedidoStatsQuery(), { wrapper: makeWrapper(qc) })
    // `placeholderData` deja `isSuccess` en true desde el primer render (con el
    // resumen vacío): hay que esperar a que la carga REAL termine, no solo a
    // que salga del estado 'pending'.
    await waitFor(() => expect(result.current.isPlaceholderData).toBe(false))

    expect(result.current.data?.total.count).toBe(1064)
    expect(result.current.data?.aproximado).toBe(false)
  })

  it('las seis cards, incluida "Impagos", coinciden con el total exacto', async () => {
    from.mockImplementation(() => tablaFake(1064))
    const qc = nuevoQueryClient()
    const { result } = renderHook(() => usePedidoStatsQuery(), { wrapper: makeWrapper(qc) })
    await waitFor(() => expect(result.current.isPlaceholderData).toBe(false))

    const s = result.current.data!
    expect(s.pendientes.count + s.enPreparacion.count + s.enCamino.count + s.entregados.count).toBe(1064)
    // 1 de cada 3 pagado ⇒ 2 de cada 3 impago, sobre 1064 filas.
    expect(s.impagos.count).toBe(1064 - Math.floor((1064 + 2) / 3))
  })

  it('si se supera el tope de seguridad, marca `aproximado` en vez de mentir un total completo', async () => {
    from.mockImplementation(() => tablaFake(25_000))
    const qc = nuevoQueryClient()
    const { result } = renderHook(() => usePedidoStatsQuery(), { wrapper: makeWrapper(qc) })
    // 20 páginas de 1.000 filas cada una: más lento que el `waitFor` por defecto.
    await waitFor(() => expect(result.current.isPlaceholderData).toBe(false), { timeout: 5000 })

    expect(result.current.data?.aproximado).toBe(true)
    expect(result.current.data?.total.count).toBe(20_000)
  })
})

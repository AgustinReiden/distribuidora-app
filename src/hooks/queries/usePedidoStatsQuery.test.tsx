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
function tablaFake(
  totalFilas: number,
  estadoPago: (i: number) => string | null = (i) => (i % 3 === 0 ? 'pagado' : 'pendiente'),
) {
  const filas = Array.from({ length: totalFilas }, (_, i) => ({
    id: i + 1,
    estado: (['pendiente', 'en_preparacion', 'asignado', 'entregado'] as const)[i % 4],
    estado_pago: estadoPago(i),
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

  it('"Impagos" cuenta todo lo que no está pagado, NULL incluido: el mismo criterio que el filtro de la lista (#794)', async () => {
    // Una fila de cada: pagado, pendiente, parcial y NULL. La lista filtra
    // `estado_pago.is.null,estado_pago.neq.pagado` (construirFiltrosPedidos):
    // si el tile dejara afuera el NULL, los dos números dejarían de coincidir.
    const estados = ['pagado', 'pendiente', 'parcial', null]
    from.mockImplementation(() => tablaFake(4, (i) => estados[i]))
    const qc = nuevoQueryClient()
    const { result } = renderHook(() => usePedidoStatsQuery(), { wrapper: makeWrapper(qc) })
    await waitFor(() => expect(result.current.isPlaceholderData).toBe(false))

    expect(result.current.data!.impagos.count).toBe(3)
    expect(result.current.data!.impagos.monto).toBe(300)
  })

  it('un vale blanco (VB) no es venta ni deuda: va en su línea "consumoInterno" y no suma a los demás buckets', async () => {
    // pendiente ZZ, entregado ZZ (impago), entregado VB (pagado), cancelado VB (total 0).
    // El cancelado sólo llega con "Ver cancelados": cuenta (como en "Total") y suma 0,
    // porque el tile filtra la lista por tipo_factura y tiene que contar lo que muestra.
    const filas = [
      { id: 1, estado: 'pendiente', estado_pago: 'pendiente', total: 100, tipo_factura: 'ZZ' },
      { id: 2, estado: 'entregado', estado_pago: 'pendiente', total: 200, tipo_factura: 'FC' },
      { id: 3, estado: 'entregado', estado_pago: 'pagado', total: 700, tipo_factura: 'VB' },
      { id: 4, estado: 'entregado', estado_pago: 'pagado', total: 50, tipo_factura: 'VB' },
      { id: 5, estado: 'cancelado', estado_pago: 'pagado', total: 0, tipo_factura: 'VB' },
    ]
    const builder: Record<string, unknown> = {}
    const encadenable = () => builder
    for (const m of ['select', 'order', 'eq', 'gte', 'lte', 'or', 'in', 'not']) builder[m] = encadenable
    builder.range = () => Promise.resolve({ data: filas, error: null })
    from.mockImplementation(() => builder)

    const qc = nuevoQueryClient()
    const { result } = renderHook(() => usePedidoStatsQuery(), { wrapper: makeWrapper(qc) })
    await waitFor(() => expect(result.current.isPlaceholderData).toBe(false))

    const s = result.current.data!
    expect(s.consumoInterno).toEqual({ count: 3, monto: 750 })
    expect(s.total).toEqual({ count: 2, monto: 300 })
    expect(s.entregados).toEqual({ count: 1, monto: 200 })
    expect(s.impagos).toEqual({ count: 2, monto: 300 })
  })

  it('el SELECT liviano pide tipo_factura (si no, el VB no se puede distinguir)', async () => {
    const selects: string[] = []
    const builder: Record<string, unknown> = {}
    const encadenable = () => builder
    for (const m of ['order', 'eq', 'gte', 'lte', 'or', 'in', 'not']) builder[m] = encadenable
    builder.select = (cols: string) => { selects.push(cols); return builder }
    builder.range = () => Promise.resolve({ data: [], error: null })
    from.mockImplementation(() => builder)

    const qc = nuevoQueryClient()
    const { result } = renderHook(() => usePedidoStatsQuery(), { wrapper: makeWrapper(qc) })
    await waitFor(() => expect(result.current.isPlaceholderData).toBe(false))

    expect(selects.length).toBeGreaterThan(0)
    expect(selects.every((s) => s.includes('tipo_factura'))).toBe(true)
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

/**
 * permisos-B4 (D10): el GPS del check-in sale de `pedido_gps`, no de la fila de `pedidos` (que
 * el chofer lee). Se pide sólo lo que dibuja el chip, por tandas de ids, sin `*` y sin embeds.
 * La consulta es sólo del admin (al resto la RLS le da cero filas): el hook se apaga sin él.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createElement, type ReactNode } from 'react'

const from = vi.fn()
const select = vi.fn()
const inFn = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: { from: (...a: unknown[]) => from(...a) },
}))
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))

import { fetchPedidosGps, usePedidosGpsQuery, PEDIDO_GPS_COLUMNAS } from './pedidoGps'

beforeEach(() => {
  from.mockReset()
  select.mockReset()
  inFn.mockReset()
  from.mockReturnValue({ select })
  select.mockReturnValue({ in: inFn })
})

describe('fetchPedidosGps', () => {
  it('lee pedido_gps (no pedidos), sólo las columnas del chip, sin repetir ids', async () => {
    inFn.mockResolvedValue({
      data: [
        { pedido_id: 7, gps_status: 'ok', gps_lat: -26.8, gps_lng: -65.2 },
        { pedido_id: 9, gps_status: 'denied', gps_lat: null, gps_lng: null },
      ],
      error: null,
    })
    const mapa = await fetchPedidosGps([9, '7', 7, ''])
    expect(from).toHaveBeenCalledWith('pedido_gps')
    expect(from).not.toHaveBeenCalledWith('pedidos')
    expect(select).toHaveBeenCalledWith(PEDIDO_GPS_COLUMNAS)
    expect(PEDIDO_GPS_COLUMNAS).not.toMatch(/\*|\(/)
    expect(inFn).toHaveBeenCalledWith('pedido_id', ['7', '9'])
    expect(mapa.get('7')?.gps_status).toBe('ok')
    expect(mapa.get('9')?.gps_status).toBe('denied')
    expect(mapa.size).toBe(2)
  })

  it('un pedido sin fila no está en el mapa (sin check-in)', async () => {
    inFn.mockResolvedValue({ data: [], error: null })
    expect((await fetchPedidosGps([1])).has('1')).toBe(false)
  })

  it('pide de a 200 ids', async () => {
    inFn.mockResolvedValue({ data: [], error: null })
    await fetchPedidosGps(Array.from({ length: 450 }, (_, i) => i + 1))
    expect(inFn).toHaveBeenCalledTimes(3)
    expect(inFn.mock.calls.map(c => (c[1] as string[]).length)).toEqual([200, 200, 50])
  })

  it('un error se tira (la tarjeta sale sin el chip)', async () => {
    inFn.mockResolvedValue({ data: null, error: { code: '42P01', message: 'no existe' } })
    await expect(fetchPedidosGps([1])).rejects.toThrow()
  })

  it('sin ids no consulta', async () => {
    expect((await fetchPedidosGps([])).size).toBe(0)
    expect(from).not.toHaveBeenCalled()
  })
})

describe('usePedidosGpsQuery', () => {
  function wrapper({ children }: { children: ReactNode }) {
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    return createElement(QueryClientProvider, { client: qc }, children)
  }

  it('apagado (quien no es admin) no consulta', () => {
    renderHook(() => usePedidosGpsQuery([1, 2], { enabled: false }), { wrapper })
    expect(from).not.toHaveBeenCalled()
  })
})

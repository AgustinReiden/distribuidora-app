/**
 * 1563-b5: la ficha no ignoraba una respuesta vieja.
 *
 * `useFichaCliente` dispara su fetch en un efecto sin cancelación: si el usuario pasa del
 * cliente A al B mientras A todavía carga, la respuesta de A llega después y pisa la de B,
 * y la ficha de B muestra los pedidos y el total de A. Y mientras B carga, seguía a la vista
 * lo de A.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor, act } from '@testing-library/react'

type Resolver = (filas: Array<Record<string, unknown>>) => void

const m = vi.hoisted(() => ({
  // Por cliente: la promesa de la query liviana de pedidos queda pendiente hasta que el test la suelte.
  pendientes: {} as Record<string, (filas: Array<Record<string, unknown>>) => void>,
  notifyError: vi.fn(),
}))

vi.mock('./base', () => {
  const tabla = (nombre: string) => {
    let cliente = ''
    const builder: Record<string, unknown> = {}
    builder.select = () => builder
    builder.order = () => builder
    builder.eq = (_col: string, valor: string) => { cliente = valor; return builder }
    builder.range = () => nombre === 'pedidos'
      ? new Promise(resolve => {
        m.pendientes[cliente] = (filas) => resolve({ data: filas, error: null })
      })
      : Promise.resolve({ data: [], error: null })
    builder.limit = () => Promise.resolve({ data: [], error: null })
    return builder
  }
  // La RPC de las notas del preventista (tanda 6 bis): sin notas.
  return { supabase: { from: (n: string) => tabla(n), rpc: () => tabla('rpc') }, notifyError: m.notifyError }
})

import { useFichaCliente } from './useFichaCliente'

const ped = (cliente: string, total: number) => ({
  id: `${cliente}-1`, cliente_id: cliente, estado: 'entregado', estado_pago: 'pagado', canal: 'app',
  fecha: '2026-10-01', created_at: '2026-10-01T15:00:00Z', tipo_factura: 'ZZ', total,
})

const soltar: (c: string, filas: Array<Record<string, unknown>>) => Promise<void> = async (c, filas) => {
  await waitFor(() => expect(m.pendientes[c]).toBeDefined())
  await act(async () => { (m.pendientes[c] as Resolver)(filas) })
}

beforeEach(() => {
  vi.clearAllMocks()
  m.pendientes = {}
})

describe('useFichaCliente — respuesta vieja (1563-b5)', () => {
  it('si llega tarde la respuesta del cliente anterior, no pisa la del actual', async () => {
    const { result, rerender } = renderHook(({ id }) => useFichaCliente(id), { initialProps: { id: '10' } })
    await waitFor(() => expect(m.pendientes['10']).toBeDefined())

    rerender({ id: '20' })
    // Primero contesta B, después A (que ya no es el cliente en pantalla).
    await soltar('20', [ped('20', 2000)])
    await waitFor(() => expect(result.current.estadisticas?.totalCompras).toBe(2000))
    await soltar('10', [ped('10', 1000)])

    expect(result.current.estadisticas?.totalCompras).toBe(2000)
    expect(result.current.loading).toBe(false)
  })

  it('mientras carga el cliente nuevo no se ve lo del anterior', async () => {
    const { result, rerender } = renderHook(({ id }) => useFichaCliente(id), { initialProps: { id: '10' } })
    await soltar('10', [ped('10', 1000)])
    await waitFor(() => expect(result.current.estadisticas?.totalCompras).toBe(1000))

    rerender({ id: '20' })

    expect(result.current.estadisticas).toBeNull()
    expect(result.current.pedidosTotales).toBe(0)
    expect(result.current.loading).toBe(true)
    await soltar('20', [ped('20', 2000)])
    await waitFor(() => expect(result.current.estadisticas?.totalCompras).toBe(2000))
  })

  it('una respuesta que llega después de cerrar la ficha no vuelve a llenarla', async () => {
    const { result, rerender } = renderHook(({ id }) => useFichaCliente(id), {
      initialProps: { id: '10' as string | null },
    })
    await waitFor(() => expect(m.pendientes['10']).toBeDefined())

    rerender({ id: null })
    await soltar('10', [ped('10', 1000)])

    expect(result.current.estadisticas).toBeNull()
    expect(result.current.loading).toBe(false)
  })

  it('el refetch del cliente actual sigue andando', async () => {
    const { result } = renderHook(() => useFichaCliente('10'))
    await soltar('10', [ped('10', 1000)])
    await waitFor(() => expect(result.current.estadisticas?.totalCompras).toBe(1000))

    delete m.pendientes['10']
    let recarga: Promise<void> = Promise.resolve()
    act(() => { recarga = result.current.refetch() })
    await soltar('10', [ped('10', 1500)])
    await act(async () => { await recarga })

    expect(result.current.estadisticas?.totalCompras).toBe(1500)
  })
})

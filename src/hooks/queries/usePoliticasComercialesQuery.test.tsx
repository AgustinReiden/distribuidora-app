/**
 * Políticas `mostrarSinStock` y `ventanaPrecioAnteriorHoras` (#1157): default,
 * mapeo, caché viejo de Dexie y la mutación de la ventana.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactNode } from 'react'

const m = vi.hoisted(() => ({
  fila: null as Record<string, unknown> | null,
  cache: null as Record<string, unknown> | null,
  colgar: false,
  rpc: vi.fn(),
}))

vi.mock('../supabase/base', () => ({
  supabase: {
    from: () => ({
      select: () => ({ maybeSingle: () => (m.colgar ? new Promise(() => {}) : Promise.resolve({ data: m.fila, error: null })) }),
    }),
    rpc: (...args: unknown[]) => m.rpc(...args),
  },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))
vi.mock('../../lib/offlineDb', () => ({
  cacheData: vi.fn(() => Promise.resolve()),
  getCachedData: vi.fn(() => Promise.resolve(m.cache)),
}))

import {
  usePoliticasComercialesQuery,
  useActualizarVentanaPrecioAnteriorMutation,
  POLITICAS_POR_DEFECTO,
} from './usePoliticasComercialesQuery'
import { cacheData } from '../../lib/offlineDb'

function wrapper({ children }: { children: ReactNode }) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

beforeEach(() => {
  m.fila = null
  m.cache = null
  m.colgar = false
  m.rpc.mockReset()
  vi.mocked(cacheData).mockClear()
})

describe('usePoliticasComercialesQuery — mostrarSinStock', () => {
  it('el default es true (lo que hacía la app antes de la política)', () => {
    expect(POLITICAS_POR_DEFECTO.mostrarSinStock).toBe(true)
  })

  it('sin fila del servidor queda en true', async () => {
    const { result } = renderHook(() => usePoliticasComercialesQuery(), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.politicas.mostrarSinStock).toBe(true)
  })

  it('false configurado se respeta (?? y no ||)', async () => {
    m.fila = { monto_minimo_pedido: 0, mostrar_sin_stock: false }
    const { result } = renderHook(() => usePoliticasComercialesQuery(), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.politicas.mostrarSinStock).toBe(false)
  })

  it('true del servidor se mapea', async () => {
    m.fila = { mostrar_sin_stock: true }
    const { result } = renderHook(() => usePoliticasComercialesQuery(), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.politicas.mostrarSinStock).toBe(true)
  })

  it('un caché de Dexie viejo, sin el campo, se mergea con los defaults', async () => {
    // Sin respuesta del servidor (offline): manda el caché, que no trae el campo.
    m.colgar = true
    m.cache = { montoMinimoPedido: 5000, comisionPctPreventista: 3 }
    const { result } = renderHook(() => usePoliticasComercialesQuery(), { wrapper })
    await waitFor(() => expect(result.current.politicas.montoMinimoPedido).toBe(5000))
    expect(result.current.politicas.mostrarSinStock).toBe(true)
    expect(result.current.politicas.diasAlertaVencimiento).toBe(60)
  })
})

describe('usePoliticasComercialesQuery — ventanaPrecioAnteriorHoras (#1157)', () => {
  it('el default es 24 (el DEFAULT de la columna, mig 363)', () => {
    expect(POLITICAS_POR_DEFECTO.ventanaPrecioAnteriorHoras).toBe(24)
  })

  it('sin fila del servidor queda en 24', async () => {
    const { result } = renderHook(() => usePoliticasComercialesQuery(), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.politicas.ventanaPrecioAnteriorHoras).toBe(24)
  })

  it('un 0 configurado se respeta (?? y no ||): es "sin tolerancia"', async () => {
    m.fila = { ventana_precio_anterior_horas: 0 }
    const { result } = renderHook(() => usePoliticasComercialesQuery(), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.politicas.ventanaPrecioAnteriorHoras).toBe(0)
  })

  it('un 48 del servidor se mapea', async () => {
    m.fila = { ventana_precio_anterior_horas: 48 }
    const { result } = renderHook(() => usePoliticasComercialesQuery(), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.politicas.ventanaPrecioAnteriorHoras).toBe(48)
  })

  it('un caché de Dexie viejo, sin el campo, se mergea en 24', async () => {
    m.colgar = true
    m.cache = { montoMinimoPedido: 5000, mostrarSinStock: false }
    const { result } = renderHook(() => usePoliticasComercialesQuery(), { wrapper })
    await waitFor(() => expect(result.current.politicas.montoMinimoPedido).toBe(5000))
    expect(result.current.politicas.ventanaPrecioAnteriorHoras).toBe(24)
    expect(result.current.politicas.mostrarSinStock).toBe(false)
  })

  it('la mutación llama la RPC con p_horas y guarda el caché con el campo, sin perder los demás', async () => {
    m.rpc.mockResolvedValue({ data: 48, error: null })
    m.cache = { ...POLITICAS_POR_DEFECTO, montoMinimoPedido: 5000, mostrarSinStock: false }
    const { result } = renderHook(() => useActualizarVentanaPrecioAnteriorMutation(), { wrapper })
    let devuelto: number | undefined
    await act(async () => { devuelto = await result.current.mutateAsync(48) })
    expect(m.rpc).toHaveBeenCalledWith('actualizar_ventana_precio_anterior', { p_horas: 48 })
    expect(devuelto).toBe(48)
    expect(cacheData).toHaveBeenCalledWith(
      'politicas_comerciales',
      expect.objectContaining({ ventanaPrecioAnteriorHoras: 48, montoMinimoPedido: 5000, mostrarSinStock: false }),
      undefined,
      1,
    )
  })

  it('si la RPC falla, la mutación rechaza y no toca el caché', async () => {
    m.rpc.mockResolvedValue({ data: null, error: { message: 'Acceso denegado: se requiere rol admin', code: 'P0001' } })
    const { result } = renderHook(() => useActualizarVentanaPrecioAnteriorMutation(), { wrapper })
    await act(async () => {
      await expect(result.current.mutateAsync(48)).rejects.toThrow('Acceso denegado: se requiere rol admin')
    })
    expect(cacheData).not.toHaveBeenCalled()
  })
})

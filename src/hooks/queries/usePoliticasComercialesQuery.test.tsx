/**
 * Política `mostrarSinStock`: default, mapeo y caché viejo de Dexie.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactNode } from 'react'

const m = vi.hoisted(() => ({
  fila: null as Record<string, unknown> | null,
  cache: null as Record<string, unknown> | null,
  colgar: false,
}))

vi.mock('../supabase/base', () => ({
  supabase: {
    from: () => ({
      select: () => ({ maybeSingle: () => (m.colgar ? new Promise(() => {}) : Promise.resolve({ data: m.fila, error: null })) }),
    }),
  },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))
vi.mock('../../lib/offlineDb', () => ({
  cacheData: vi.fn(() => Promise.resolve()),
  getCachedData: vi.fn(() => Promise.resolve(m.cache)),
}))

import { usePoliticasComercialesQuery, POLITICAS_POR_DEFECTO } from './usePoliticasComercialesQuery'

function wrapper({ children }: { children: ReactNode }) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

beforeEach(() => {
  m.fila = null
  m.cache = null
  m.colgar = false
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

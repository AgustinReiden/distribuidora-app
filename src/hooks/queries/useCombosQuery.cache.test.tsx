/**
 * Combos vigentes sin señal (#1194): la última lista que el teléfono vio para
 * esa fecha se guarda en Dexie y se usa cuando la RPC no contesta. Un caché de
 * otro día no se usa.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactNode } from 'react'
import { fechaLocalISO } from '../../utils/formatters'

const m = vi.hoisted(() => ({
  cache: null as unknown,
  rpc: vi.fn(),
}))

vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...args: unknown[]) => m.rpc(...args) },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))
vi.mock('../../lib/offlineDb', () => ({
  cacheData: vi.fn(() => Promise.resolve()),
  getCachedData: vi.fn(() => Promise.resolve(m.cache)),
}))

import { useCombosVigentesQuery } from './useCombosQuery'
import { cacheData } from '../../lib/offlineDb'

function wrapper({ children }: { children: ReactNode }) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

const COMBO = {
  id: '500',
  nombre: 'Fernet + Coca',
  precio: 11000,
  combinaEscalas: false,
  prioridad: 0,
  componentes: [{ componente: 1, cantidad: 1, productos: ['10'] }],
  topeRestante: null,
}

beforeEach(() => {
  m.cache = null
  m.rpc.mockReset()
  vi.mocked(cacheData).mockClear()
})

describe('useCombosVigentesQuery — caché offline', () => {
  it('con señal guarda la lista del día en Dexie', async () => {
    m.rpc.mockResolvedValue({
      data: [{ id: 500, nombre: 'Fernet + Coca', precio: '11000', combina_escalas: false, prioridad: 0, componentes: [{ componente: 1, cantidad: 1, productos: [10] }], tope_restante: null }],
      error: null,
    })
    const { result } = renderHook(() => useCombosVigentesQuery(), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data).toEqual([COMBO])
    expect(cacheData).toHaveBeenCalledWith('combos_vigentes', { fecha: fechaLocalISO(), combos: [COMBO] }, undefined, 1)
  })

  it('sin señal usa la lista cacheada de ese día', async () => {
    m.cache = { fecha: fechaLocalISO(), combos: [COMBO] }
    m.rpc.mockReturnValue(new Promise(() => {}))
    const { result } = renderHook(() => useCombosVigentesQuery(), { wrapper })
    await waitFor(() => expect(result.current.data).toEqual([COMBO]))
    expect(result.current.isLoading).toBe(false)
  })

  it('un caché de otro día no se usa', async () => {
    m.cache = { fecha: '2000-01-01', combos: [COMBO] }
    m.rpc.mockReturnValue(new Promise(() => {}))
    const { result } = renderHook(() => useCombosVigentesQuery(), { wrapper })
    await new Promise(r => setTimeout(r, 20))
    expect(result.current.data).toBeUndefined()
  })

  it('la consulta de una edición no pisa el caché general', async () => {
    m.rpc.mockResolvedValue({ data: [], error: null })
    const { result } = renderHook(() => useCombosVigentesQuery(undefined, '77'), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(cacheData).not.toHaveBeenCalled()
  })
})

/**
 * El historial de control de stock ya no se corta en 100 (#1599, 1599-b3):
 * el hook acepta el límite y lo manda a la consulta.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const limit = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    from: () => {
      const b = {
        select: () => b,
        order: () => b,
        limit: async (n: number) => {
          limit(n)
          return { data: [], error: null }
        },
      }
      return b
    },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useControlStockSesionesQuery, SESIONES_POR_PAGINA } from './useControlStockQuery'

function wrapper() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
}

beforeEach(() => limit.mockClear())

describe('useControlStockSesionesQuery — límite', () => {
  it('por defecto pide una página', async () => {
    renderHook(() => useControlStockSesionesQuery(), { wrapper: wrapper() })
    await waitFor(() => expect(limit).toHaveBeenCalledWith(SESIONES_POR_PAGINA))
  })

  it('con un límite mayor pide más sesiones, no las mismas 100', async () => {
    renderHook(() => useControlStockSesionesQuery(true, 300), { wrapper: wrapper() })
    await waitFor(() => expect(limit).toHaveBeenCalledWith(300))
  })
})

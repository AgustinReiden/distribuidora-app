/**
 * Impacto del monto mínimo: no cuenta los vales blancos (VB), a los que el mínimo
 * de pedido no les rige (N6). `tipo_factura` es nullable, así que el filtro es un
 * `or` con IS NULL (un `neq` pelado descartaría los NULL).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactNode } from 'react'

const m = vi.hoisted(() => ({
  ors: [] as string[],
  neqs: [] as Array<[string, unknown]>,
  filas: [] as Array<{ total: number }>,
}))

vi.mock('../supabase/base', () => ({
  supabase: {
    from: () => {
      const builder: Record<string, unknown> = {}
      builder.select = () => builder
      builder.neq = (col: string, val: unknown) => { m.neqs.push([col, val]); return builder }
      builder.or = (f: string) => { m.ors.push(f); return builder }
      builder.gte = () => Promise.resolve({ data: m.filas, error: null })
      return builder
    },
  },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))
vi.mock('../../lib/offlineDb', () => ({
  cacheData: vi.fn(() => Promise.resolve()),
  getCachedData: vi.fn(() => Promise.resolve(null)),
}))

import { useImpactoMinimoQuery } from './usePoliticasComercialesQuery'

function wrapper({ children }: { children: ReactNode }) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

beforeEach(() => {
  m.ors = []
  m.neqs = []
  m.filas = [{ total: 5000 }, { total: 30000 }, { total: 10000 }]
})

describe('useImpactoMinimoQuery', () => {
  it('excluye cancelados y vales blancos (conservando tipo_factura NULL)', async () => {
    const { result } = renderHook(() => useImpactoMinimoQuery(20000), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(m.neqs).toContainEqual(['estado', 'cancelado'])
    // Un anulado es la misma baja (#1080): total 0, no es un pedido que el mínimo frene.
    expect(m.neqs).toContainEqual(['estado', 'anulado'])
    expect(m.ors).toContain('tipo_factura.is.null,tipo_factura.neq.VB')
  })

  it('cuenta los pedidos que quedarían bajo el mínimo propuesto', async () => {
    const { result } = renderHook(() => useImpactoMinimoQuery(20000), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data).toEqual({ total: 3, bloqueados: 2 })
  })
})

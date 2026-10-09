/**
 * #1052: "Por Preventista" muestra SÓLO la sucursal activa.
 *
 * `reporte_ventas_por_preventista` interpreta `p_sucursal_id: null` como "toda
 * la red". El hook ya tenía la sucursal activa en la queryKey pero mandaba null
 * al RPC: la caché se separaba por sucursal y la respuesta era siempre la misma.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()
let sucursalActiva: number | null = 2

vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...args: unknown[]) => rpc(...args), from: vi.fn() },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: sucursalActiva }),
}))

import { useReportePreventistasQuery } from './useMetricasQuery'

function wrapper() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return function W({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

describe('useReportePreventistasQuery › sucursal activa (#1052)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    sucursalActiva = 2
    rpc.mockResolvedValue({ data: [], error: null })
  })

  it('le pasa la sucursal activa al RPC, no null (que sería la red)', async () => {
    renderHook(() => useReportePreventistasQuery('2026-10-01', '2026-10-31'), { wrapper: wrapper() })
    await waitFor(() => expect(rpc).toHaveBeenCalledTimes(1))
    expect(rpc).toHaveBeenCalledWith('reporte_ventas_por_preventista', {
      p_desde: '2026-10-01',
      p_hasta: '2026-10-31',
      p_sucursal_id: 2,
    })
  })

  it('mientras la sucursal no está resuelta no consulta: null sería la red', async () => {
    sucursalActiva = null
    const { result } = renderHook(
      () => useReportePreventistasQuery('2026-10-01', '2026-10-31'),
      { wrapper: wrapper() },
    )
    // Un tick para que, si estuviera habilitada, ya hubiera disparado.
    await new Promise((r) => setTimeout(r, 20))
    expect(rpc).not.toHaveBeenCalled()
    expect(result.current.fetchStatus).toBe('idle')
  })
})

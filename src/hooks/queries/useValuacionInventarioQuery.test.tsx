/**
 * #1052: el hook respeta lo que le pasan. `null` sigue siendo "toda la red" en
 * el RPC, pero ahora es una decisión explícita de quien llama, no el default de
 * la pantalla de Valuación (que pasa la sucursal activa).
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../../lib/supabase', () => ({
  supabase: { rpc: (...args: unknown[]) => rpc(...args) },
}))

import { useValuacionInventarioQuery } from './useValuacionInventarioQuery'

function wrapper() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return function W({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

describe('useValuacionInventarioQuery', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    rpc.mockResolvedValue({ data: { productos: [] }, error: null })
  })

  it('le pasa al RPC la sucursal que recibe', async () => {
    renderHook(() => useValuacionInventarioQuery(2), { wrapper: wrapper() })
    await waitFor(() => expect(rpc).toHaveBeenCalledTimes(1))
    expect(rpc).toHaveBeenCalledWith('reporte_valuacion_inventario', { p_sucursal_id: 2 })
  })

  it('null explícito sigue siendo la red', async () => {
    renderHook(() => useValuacionInventarioQuery(null), { wrapper: wrapper() })
    await waitFor(() => expect(rpc).toHaveBeenCalledTimes(1))
    expect(rpc).toHaveBeenCalledWith('reporte_valuacion_inventario', { p_sucursal_id: null })
  })

  it('con enabled en false no consulta', async () => {
    const { result } = renderHook(() => useValuacionInventarioQuery(null, false), { wrapper: wrapper() })
    await new Promise((r) => setTimeout(r, 20))
    expect(rpc).not.toHaveBeenCalled()
    expect(result.current.fetchStatus).toBe('idle')
  })
})

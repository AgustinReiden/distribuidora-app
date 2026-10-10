/**
 * #1061: el rendimiento del equipo no se pide hasta saber la sucursal activa.
 *
 * En `rendimiento_preventistas`, `p_sucursal_id: null` significa "todas las
 * sucursales asignadas al admin" (la red). El hook mandaba `currentSucursalId`
 * tal cual, así que con la sucursal sin resolver consultaba la red entera.
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

import { useRendimientoPreventistasQuery } from './useMetasPreventistaQuery'

function crearWrapper() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return function W({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

const esperarUnTick = () => new Promise((r) => setTimeout(r, 20))

describe('useRendimientoPreventistasQuery › sucursal activa (#1061)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    sucursalActiva = 2
    rpc.mockResolvedValue({ data: { preventistas: [] }, error: null })
  })

  it('manda la sucursal activa al RPC', async () => {
    renderHook(() => useRendimientoPreventistasQuery('2026-10-01'), { wrapper: crearWrapper() })
    await waitFor(() => expect(rpc).toHaveBeenCalledTimes(1))
    expect(rpc).toHaveBeenCalledWith('rendimiento_preventistas', {
      p_sucursal_id: 2,
      p_periodo: '2026-10-01',
    })
  })

  it('con la sucursal sin resolver no consulta: null sería la red', async () => {
    sucursalActiva = null
    const { result } = renderHook(
      () => useRendimientoPreventistasQuery('2026-10-01'),
      { wrapper: crearWrapper() },
    )
    await esperarUnTick()
    expect(rpc).not.toHaveBeenCalled()
    expect(result.current.fetchStatus).toBe('idle')
  })

  it('cuando la sucursal se resuelve consulta con ella, y nunca con null', async () => {
    sucursalActiva = null
    const wrapper = crearWrapper()
    const { rerender } = renderHook(
      () => useRendimientoPreventistasQuery('2026-10-01'),
      { wrapper },
    )
    await esperarUnTick()
    expect(rpc).not.toHaveBeenCalled()

    sucursalActiva = 3
    rerender()
    await waitFor(() => expect(rpc).toHaveBeenCalledTimes(1))
    expect(rpc).toHaveBeenCalledWith('rendimiento_preventistas', expect.objectContaining({ p_sucursal_id: 3 }))
    expect(rpc.mock.calls.every(([, args]) => args.p_sucursal_id !== null)).toBe(true)
  })

  it('respeta el enabled del llamador (no admin: no consulta)', async () => {
    const { result } = renderHook(
      () => useRendimientoPreventistasQuery('2026-10-01', false),
      { wrapper: crearWrapper() },
    )
    await esperarUnTick()
    expect(rpc).not.toHaveBeenCalled()
    expect(result.current.fetchStatus).toBe('idle')
  })
})

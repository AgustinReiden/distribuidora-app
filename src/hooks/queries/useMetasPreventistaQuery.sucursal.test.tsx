/**
 * #1061: el rendimiento del equipo no se pide hasta saber la sucursal activa.
 *
 * En `rendimiento_preventistas`, `p_sucursal_id: null` significa "todas las
 * sucursales asignadas al admin" (la red). El hook mandaba `currentSucursalId`
 * tal cual, así que con la sucursal sin resolver consultaba la red entera.
 *
 * #1082: el avance y la lista de metas no mandan la sucursal, la acota la RLS
 * por el header. Sin sucursal resuelta el header no va, el server cae a la
 * `es_default` (que puede no ser la activa) y el resultado se cacheaba bajo
 * la key `null`.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()
const from = vi.fn()
let sucursalActiva: number | null = 2

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpc(...args),
    from: (...args: unknown[]) => from(...args),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: sucursalActiva }),
}))

import {
  useAvanceMetasQuery,
  useMetasPreventistaQuery,
  useRendimientoPreventistasQuery,
} from './useMetasPreventistaQuery'

function crearWrapper(qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })) {
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

describe('useAvanceMetasQuery y useMetasPreventistaQuery › sucursal activa (#1082)', () => {
  // La lista encadena select/eq/order y se await-ea al final.
  const consulta: Record<string, unknown> = {
    select: () => consulta,
    eq: () => consulta,
    order: () => consulta,
    then: (resolve: (v: unknown) => void) => resolve({ data: [], error: null }),
  }

  const useAmbas = (enabled = true) => [
    useAvanceMetasQuery(undefined, '2026-10-01', enabled),
    useMetasPreventistaQuery('2026-10-01', enabled),
  ] as const

  beforeEach(() => {
    vi.clearAllMocks()
    sucursalActiva = 2
    rpc.mockResolvedValue({ data: { metas: [] }, error: null })
    from.mockReturnValue(consulta)
  })

  it('con la sucursal sin resolver no consultan', async () => {
    sucursalActiva = null
    const { result } = renderHook(() => useAmbas(), { wrapper: crearWrapper() })
    await esperarUnTick()
    expect(rpc).not.toHaveBeenCalled()
    expect(from).not.toHaveBeenCalled()
    expect(result.current.map((q) => q.fetchStatus)).toEqual(['idle', 'idle'])
  })

  it('cuando la sucursal se resuelve consultan una vez y no cachean nada bajo null', async () => {
    sucursalActiva = null
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const { rerender } = renderHook(() => useAmbas(), { wrapper: crearWrapper(qc) })
    await esperarUnTick()
    expect(rpc).not.toHaveBeenCalled()
    expect(from).not.toHaveBeenCalled()

    sucursalActiva = 3
    rerender()
    await waitFor(() => {
      expect(rpc).toHaveBeenCalledTimes(1)
      expect(from).toHaveBeenCalledTimes(1)
    })
    expect(rpc).toHaveBeenCalledWith('avance_metas_preventista', expect.anything())
    expect(from).toHaveBeenCalledWith('metas_preventista')
    const datos = (sucursal: number | null) =>
      qc.getQueriesData({ queryKey: ['metas-preventista', sucursal] }).map(([, d]) => d)
    await waitFor(() => expect(datos(3)).toEqual([expect.anything(), expect.anything()]))
    expect(datos(null).every((d) => d === undefined)).toBe(true)
  })

  it('respetan el enabled del llamador', async () => {
    const { result } = renderHook(() => useAmbas(false), { wrapper: crearWrapper() })
    await esperarUnTick()
    expect(rpc).not.toHaveBeenCalled()
    expect(from).not.toHaveBeenCalled()
    expect(result.current.map((q) => q.fetchStatus)).toEqual(['idle', 'idle'])
  })
})

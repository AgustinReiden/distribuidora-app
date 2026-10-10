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
const from = vi.fn()
let sucursalActiva: number | null = 2

vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...args: unknown[]) => rpc(...args), from: (...args: unknown[]) => from(...args) },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: sucursalActiva }),
}))

import {
  useRendimientoPreventistasQuery,
  useAvanceMetasQuery,
  useMetasPreventistaQuery,
} from './useMetasPreventistaQuery'

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

/**
 * #1082: los otros dos hooks de metas también esperan a la sucursal. No la mandan
 * como parámetro (no pedirían la red), pero sin header X-Sucursal-ID la RLS cae
 * en la sucursal `es_default` del usuario, que puede no ser la activa, y el
 * resultado quedaba cacheado bajo la key `null`.
 */
describe('useAvanceMetasQuery › sucursal activa (#1082)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    sucursalActiva = 2
    rpc.mockResolvedValue({ data: { metas: [] }, error: null })
  })

  it('con la sucursal resuelta consulta el avance', async () => {
    renderHook(() => useAvanceMetasQuery(undefined, '2026-10-01'), { wrapper: crearWrapper() })
    await waitFor(() => expect(rpc).toHaveBeenCalledTimes(1))
    expect(rpc).toHaveBeenCalledWith('avance_metas_preventista', {
      p_preventista_id: null,
      p_periodo: '2026-10-01',
    })
  })

  it('con la sucursal sin resolver no consulta', async () => {
    sucursalActiva = null
    const { result } = renderHook(
      () => useAvanceMetasQuery(undefined, '2026-10-01'),
      { wrapper: crearWrapper() },
    )
    await esperarUnTick()
    expect(rpc).not.toHaveBeenCalled()
    expect(result.current.fetchStatus).toBe('idle')
  })

  it('cuando la sucursal se resuelve consulta una sola vez', async () => {
    sucursalActiva = null
    const wrapper = crearWrapper()
    const { rerender } = renderHook(
      () => useAvanceMetasQuery(undefined, '2026-10-01'),
      { wrapper },
    )
    await esperarUnTick()
    expect(rpc).not.toHaveBeenCalled()

    sucursalActiva = 3
    rerender()
    await waitFor(() => expect(rpc).toHaveBeenCalledTimes(1))
  })

  it('respeta el enabled del llamador aunque la sucursal esté resuelta', async () => {
    const { result } = renderHook(
      () => useAvanceMetasQuery(undefined, '2026-10-01', false),
      { wrapper: crearWrapper() },
    )
    await esperarUnTick()
    expect(rpc).not.toHaveBeenCalled()
    expect(result.current.fetchStatus).toBe('idle')
  })
})

describe('useMetasPreventistaQuery › sucursal activa (#1082)', () => {
  // from('metas_preventista').select().eq().eq().order().order() -> Promise
  const cadena = () => {
    const c: Record<string, unknown> = {}
    for (const m of ['select', 'eq']) c[m] = vi.fn(() => c)
    c.order = vi.fn()
      .mockReturnValueOnce(c)
      .mockResolvedValueOnce({ data: [], error: null })
    return c
  }

  beforeEach(() => {
    vi.clearAllMocks()
    sucursalActiva = 2
    from.mockImplementation(() => cadena())
  })

  it('con la sucursal resuelta consulta las metas', async () => {
    renderHook(() => useMetasPreventistaQuery('2026-10-01'), { wrapper: crearWrapper() })
    await waitFor(() => expect(from).toHaveBeenCalledWith('metas_preventista'))
  })

  it('con la sucursal sin resolver no consulta', async () => {
    sucursalActiva = null
    const { result } = renderHook(
      () => useMetasPreventistaQuery('2026-10-01'),
      { wrapper: crearWrapper() },
    )
    await esperarUnTick()
    expect(from).not.toHaveBeenCalled()
    expect(result.current.fetchStatus).toBe('idle')
  })

  it('cuando la sucursal se resuelve consulta una sola vez', async () => {
    sucursalActiva = null
    const wrapper = crearWrapper()
    const { rerender } = renderHook(
      () => useMetasPreventistaQuery('2026-10-01'),
      { wrapper },
    )
    await esperarUnTick()
    expect(from).not.toHaveBeenCalled()

    sucursalActiva = 3
    rerender()
    await waitFor(() => expect(from).toHaveBeenCalledTimes(1))
  })

  it('respeta el enabled del llamador aunque la sucursal esté resuelta', async () => {
    const { result } = renderHook(
      () => useMetasPreventistaQuery('2026-10-01', false),
      { wrapper: crearWrapper() },
    )
    await esperarUnTick()
    expect(from).not.toHaveBeenCalled()
    expect(result.current.fetchStatus).toBe('idle')
  })
})

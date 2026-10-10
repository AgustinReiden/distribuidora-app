/**
 * #1061: el cálculo de comisiones no se pide hasta saber la sucursal activa.
 *
 * `calcular_comisiones` interpreta `p_sucursal_ids: null` como "todas las
 * sucursales asignadas al admin", o sea la red. El hook caía a `null` cuando
 * `currentSucursalId` todavía no se había resuelto, así que durante el arranque
 * consultaba la red entera aunque la pantalla fuera de una sucursal.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()
let sucursalActiva: number | null = 2

vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...args: unknown[]) => rpc(...args) },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: sucursalActiva }),
}))

import { useCalcularComisionesQuery } from './useComisionesQuery'

function crearWrapper() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return function W({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

const esperarUnTick = () => new Promise((r) => setTimeout(r, 20))

describe('useCalcularComisionesQuery › sucursal activa (#1061)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    sucursalActiva = 2
    rpc.mockResolvedValue({ data: { preventistas: [] }, error: null })
  })

  it('sin scope explícito manda la sucursal activa', async () => {
    renderHook(() => useCalcularComisionesQuery('2026-10-01', '2026-10-31'), { wrapper: crearWrapper() })
    await waitFor(() => expect(rpc).toHaveBeenCalledTimes(1))
    expect(rpc).toHaveBeenCalledWith('calcular_comisiones', {
      p_desde: '2026-10-01',
      p_hasta: '2026-10-31',
      p_sucursal_ids: [2],
    })
  })

  it('con la sucursal sin resolver no consulta: null sería la red', async () => {
    sucursalActiva = null
    const { result } = renderHook(
      () => useCalcularComisionesQuery('2026-10-01', '2026-10-31'),
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
      () => useCalcularComisionesQuery('2026-10-01', '2026-10-31'),
      { wrapper },
    )
    await esperarUnTick()
    expect(rpc).not.toHaveBeenCalled()

    sucursalActiva = 3
    rerender()
    await waitFor(() => expect(rpc).toHaveBeenCalledTimes(1))
    expect(rpc).toHaveBeenCalledWith('calcular_comisiones', expect.objectContaining({ p_sucursal_ids: [3] }))
    expect(rpc.mock.calls.every(([, args]) => args.p_sucursal_ids !== null)).toBe(true)
  })

  it('un scope explícito null (la red pedida a propósito) sigue consultando aunque no haya sucursal', async () => {
    sucursalActiva = null
    renderHook(
      () => useCalcularComisionesQuery('2026-10-01', '2026-10-31', true, null),
      { wrapper: crearWrapper() },
    )
    await waitFor(() => expect(rpc).toHaveBeenCalledTimes(1))
    expect(rpc).toHaveBeenCalledWith('calcular_comisiones', expect.objectContaining({ p_sucursal_ids: null }))
  })

  it('un scope explícito con sucursales se respeta tal cual', async () => {
    sucursalActiva = 2
    renderHook(
      () => useCalcularComisionesQuery('2026-10-01', '2026-10-31', true, [1, 3]),
      { wrapper: crearWrapper() },
    )
    await waitFor(() => expect(rpc).toHaveBeenCalledTimes(1))
    expect(rpc).toHaveBeenCalledWith('calcular_comisiones', expect.objectContaining({ p_sucursal_ids: [1, 3] }))
  })
})

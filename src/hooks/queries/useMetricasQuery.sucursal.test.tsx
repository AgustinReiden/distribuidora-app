/**
 * #1061: las métricas del dashboard no se piden hasta saber la sucursal activa.
 *
 * `useMetricasQuery` no manda la sucursal como parámetro: la acota la RLS con el
 * header X-Sucursal-ID (`current_sucursal_id()`). Sin header, esa función cae a
 * la sucursal `es_default` del usuario, que puede no ser la activa (la activa
 * sale de localStorage). La consulta no trae la red, pero sí podía traer OTRA
 * sucursal y guardarla bajo la key `null`.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const from = vi.fn()
let sucursalActiva: number | null = 2

vi.mock('../supabase/base', () => ({
  supabase: { from: (...args: unknown[]) => from(...args), rpc: vi.fn() },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: sucursalActiva }),
}))

import { useMetricasQuery } from './useMetricasQuery'

function crearWrapper() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return function W({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

const esperarUnTick = () => new Promise((r) => setTimeout(r, 20))

describe('useMetricasQuery › sucursal activa (#1061)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    sucursalActiva = 2
    // Alcanza con saber si se intentó consultar: el resultado no importa.
    from.mockImplementation(() => {
      throw new Error('consulta de prueba')
    })
  })

  it('con la sucursal resuelta consulta pedidos', async () => {
    renderHook(() => useMetricasQuery('mes'), { wrapper: crearWrapper() })
    await waitFor(() => expect(from).toHaveBeenCalledWith('pedidos'))
  })

  it('con la sucursal sin resolver no consulta nada', async () => {
    sucursalActiva = null
    const { result } = renderHook(() => useMetricasQuery('mes'), { wrapper: crearWrapper() })
    await esperarUnTick()
    expect(from).not.toHaveBeenCalled()
    expect(result.current.fetchStatus).toBe('idle')
  })

  it('cuando la sucursal se resuelve consulta', async () => {
    sucursalActiva = null
    const wrapper = crearWrapper()
    const { rerender } = renderHook(() => useMetricasQuery('mes'), { wrapper })
    await esperarUnTick()
    expect(from).not.toHaveBeenCalled()

    sucursalActiva = 3
    rerender()
    await waitFor(() => expect(from).toHaveBeenCalledWith('pedidos'))
  })

  it('respeta el enabled del llamador', async () => {
    const { result } = renderHook(
      () => useMetricasQuery('mes', null, null, null, false),
      { wrapper: crearWrapper() },
    )
    await esperarUnTick()
    expect(from).not.toHaveBeenCalled()
    expect(result.current.fetchStatus).toBe('idle')
  })
})

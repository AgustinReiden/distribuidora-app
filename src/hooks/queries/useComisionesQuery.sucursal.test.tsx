/**
 * #1048 · Una regla de comisión nace atada a la sucursal activa.
 *
 * Los admins no ven toda la red (cada uno tiene sus sucursales asignadas), y una
 * regla con `sucursal_id` NULL rige en TODAS. El modal no elige sucursal, así
 * que la mutación mandaba siempre NULL: cualquier admin creaba una regla que le
 * cambiaba la comisión a vendedores de una sucursal que no administra.
 * `guardar_comision_regla` ahora rechaza la regla global salvo para un admin
 * asignado a todas; el front tiene que mandar la sucursal activa.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...args: unknown[]) => rpc(...args) },
}))

let sucursalActiva: number | null = 2

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: sucursalActiva }),
}))

import { useGuardarComisionReglaMutation } from './useComisionesQuery'

function wrapper({ children }: { children: React.ReactNode }) {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

describe('guardar regla de comisión (#1048)', () => {
  beforeEach(() => {
    sucursalActiva = 2
    rpc.mockReset()
    rpc.mockResolvedValue({ data: 7, error: null })
  })

  it('sin sucursal explícita, la regla va a la sucursal activa', async () => {
    const { result } = renderHook(() => useGuardarComisionReglaMutation(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ porcentaje: 3, preventistaId: 'p1' })
    })
    expect(rpc).toHaveBeenCalledWith('guardar_comision_regla', expect.objectContaining({ p_sucursal_id: 2 }))
  })

  it('sin sucursal activa no manda nada: no la convierte en regla global', async () => {
    sucursalActiva = null
    const { result } = renderHook(() => useGuardarComisionReglaMutation(), { wrapper })
    await act(async () => {
      await expect(result.current.mutateAsync({ porcentaje: 3 })).rejects.toThrow(/sucursal/i)
    })
    expect(rpc).not.toHaveBeenCalled()
  })

  it('una sucursal explícita se respeta, y null sigue pidiendo la regla global', async () => {
    const { result } = renderHook(() => useGuardarComisionReglaMutation(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ porcentaje: 3, sucursalId: 1 })
    })
    expect(rpc).toHaveBeenLastCalledWith('guardar_comision_regla', expect.objectContaining({ p_sucursal_id: 1 }))

    await act(async () => {
      await result.current.mutateAsync({ porcentaje: 3, sucursalId: null })
    })
    expect(rpc).toHaveBeenLastCalledWith('guardar_comision_regla', expect.objectContaining({ p_sucursal_id: null }))
  })
})

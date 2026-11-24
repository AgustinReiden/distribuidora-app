/**
 * gestion-B12 (tanda 6, #1603): las mutaciones de movimientos entre sucursales invalidaban sólo en
 * `onSuccess`. Si el otro lado ya había resuelto el envío (error «ya fue aceptado»), la lista quedaba
 * con el estado viejo hasta que vencía su `staleTime` de 60 segundos.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...a: unknown[]) => rpc(...a) },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 2 }),
}))

import {
  useAceptarMovimientoMutation,
  useDenegarMovimientoMutation,
  useCancelarMovimientoMutation,
} from './useMovimientosQuery'

function montar<T>(hook: () => T) {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  const invalidar = vi.spyOn(qc, 'invalidateQueries')
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return { invalidar, ...renderHook(hook, { wrapper }) }
}

describe('gestion-B12: un rechazo del server también refresca la lista de movimientos', () => {
  beforeEach(() => rpc.mockReset())

  it('aceptar un envío que ya estaba aceptado vuelve a leer los movimientos', async () => {
    rpc.mockResolvedValue({ data: { success: false, error: 'El movimiento ya fue aceptado' }, error: null })
    const { result, invalidar } = montar(useAceptarMovimientoMutation)
    await expect(result.current.mutateAsync({ movimientoId: 5, resoluciones: [] })).rejects.toBeTruthy()
    expect(invalidar).toHaveBeenCalledWith({ queryKey: ['movimientos', 2] })
  })

  it('denegar y cancelar, rechazados, también la refrescan', async () => {
    rpc.mockResolvedValue({ data: { success: false, error: 'El movimiento ya fue resuelto' }, error: null })
    const den = montar(useDenegarMovimientoMutation)
    await expect(den.result.current.mutateAsync({ movimientoId: 5 })).rejects.toBeTruthy()
    expect(den.invalidar).toHaveBeenCalledWith({ queryKey: ['movimientos', 2] })

    const can = montar(useCancelarMovimientoMutation)
    await expect(can.result.current.mutateAsync({ movimientoId: 5 } as never)).rejects.toBeTruthy()
    expect(can.invalidar).toHaveBeenCalledWith({ queryKey: ['movimientos', 2] })
  })
})

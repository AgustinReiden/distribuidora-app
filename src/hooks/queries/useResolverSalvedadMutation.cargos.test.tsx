/**
 * Gastos 7: `resolver_salvedad` recibe `p_cargos` (a quién se le carga el costo) en la misma
 * llamada. Sin líneas viaja `null`, y el encargado (que no ve la sección) nunca manda líneas.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { ReactNode } from 'react'
import { renderHook, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...a: unknown[]) => rpc(...a) },
  notifyError: vi.fn(),
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 2 }),
}))

import { useResolverSalvedadMutation } from './useSalvedadesQuery'

function montar() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return { qc, ...renderHook(() => useResolverSalvedadMutation(), { wrapper }) }
}

describe('useResolverSalvedadMutation — cargos a empleados (gastos 7)', () => {
  beforeEach(() => {
    rpc.mockReset()
    rpc.mockResolvedValue({ data: { success: true, nuevo_estado: 'descuento_transportista' }, error: null })
  })

  it('manda los cargos como [{empleado_id, monto}] en la misma llamada', async () => {
    const { qc, result } = montar()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')

    await act(async () => {
      await result.current.mutateAsync({
        salvedadId: '5',
        estadoResolucion: 'descuento_transportista',
        notas: 'Se cayó el pallet',
        cargos: [{ empleado_id: 4, monto: 1500.5 }, { empleado_id: 7, monto: 300 }],
      })
    })

    expect(rpc).toHaveBeenCalledTimes(1)
    expect(rpc).toHaveBeenCalledWith('resolver_salvedad', {
      p_salvedad_id: 5,
      p_estado_resolucion: 'descuento_transportista',
      p_notas: 'Se cayó el pallet',
      p_pedido_reprogramado_id: null,
      p_cargos: [{ empleado_id: 4, monto: 1500.5 }, { empleado_id: 7, monto: 300 }],
    })
    // La cuenta de cada empleado cambió.
    expect(invalidar).toHaveBeenCalledWith({ queryKey: ['personal'] })
  })

  it('sin cargos manda p_cargos null y no toca la cuenta del personal', async () => {
    const { qc, result } = montar()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')

    await act(async () => {
      await result.current.mutateAsync({ salvedadId: '5', estadoResolucion: 'nota_credito', notas: 'Va por NC' })
    })

    expect(rpc.mock.calls[0][1]).toMatchObject({ p_cargos: null })
    expect(invalidar).not.toHaveBeenCalledWith({ queryKey: ['personal'] })
  })
})

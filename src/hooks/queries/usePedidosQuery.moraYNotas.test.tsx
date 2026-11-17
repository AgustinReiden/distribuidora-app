/**
 * 1544-b1 (#1544): cancelar, cambiar de cliente y cobrar mueven la deuda de las boletas, pero la
 * lista de deudores en mora (`['deudores-mora']`) y las notas de crédito con su saldo por imputar
 * (`['notas_credito_venta']`) quedaban viejas: sólo `useImputarCredito` las invalidaba.
 *
 * Cancelar y cambiar de cliente aplican además el crédito que dejan (COB-2, #1512), así que mueven
 * las dos listas; un cobro sólo la mora. Las dos claves existen de verdad: las leen
 * `useDeudoresMoraQuery` y `useNotasCreditoVentaQuery`/`useImputarCreditoQuery`.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpc(...args),
    auth: { getUser: () => Promise.resolve({ data: { user: { id: 'u1' } } }) },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import {
  useCancelarPedidoMutation,
  useCambiarClientePedidoMutation,
  usePagosMasivosMutation,
  useEntregaYPagoMasivosMutation,
} from './usePedidosQuery'

function montar<T>(hook: () => T) {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  const spy = vi.spyOn(qc, 'invalidateQueries')
  const { result } = renderHook(hook, {
    wrapper: ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    ),
  })
  return { result, spy }
}

const MORA = { queryKey: ['deudores-mora'] }
const NOTAS = { queryKey: ['notas_credito_venta'] }

beforeEach(() => {
  rpc.mockReset()
})

describe('mutations de pedidos — la mora y las notas de crédito (1544-b1)', () => {
  it('cancelar un pedido invalida la mora y las notas de crédito', async () => {
    rpc.mockResolvedValue({ data: { success: true }, error: null })
    const { result, spy } = montar(() => useCancelarPedidoMutation())

    result.current.mutate({ pedidoId: '10', motivo: 'El cliente no lo quiso' })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(spy).toHaveBeenCalledWith(MORA)
    expect(spy).toHaveBeenCalledWith(NOTAS)
  })

  it('cambiar el cliente de un pedido invalida la mora y las notas de crédito', async () => {
    rpc.mockResolvedValue({ data: { success: true, nuevo_pedido_id: '11' }, error: null })
    const { result, spy } = montar(() => useCambiarClientePedidoMutation())

    result.current.mutate({
      pedidoId: '10', nuevoClienteId: '7', usuarioId: 'u1', items: [], total: 1000,
    } as unknown as Parameters<typeof result.current.mutate>[0])

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(spy).toHaveBeenCalledWith(MORA)
    expect(spy).toHaveBeenCalledWith(NOTAS)
  })

  it('el cobro masivo invalida la mora (las notas no cambian)', async () => {
    rpc.mockResolvedValue({ data: null, error: null })
    const { result, spy } = montar(() => usePagosMasivosMutation())

    result.current.mutate({ pedidoIds: ['10', '11'], formaPago: 'efectivo', fecha: '2026-11-10' })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(spy).toHaveBeenCalledWith(MORA)
    expect(spy).not.toHaveBeenCalledWith(NOTAS)
  })

  it('entregar y cobrar en un paso invalida la mora', async () => {
    rpc.mockResolvedValue({ data: 1, error: null })
    const { result, spy } = montar(() => useEntregaYPagoMasivosMutation())

    result.current.mutate({
      idsEntregar: [], idsCobrar: ['10'], transportistaId: 't1', formaPago: 'efectivo', fecha: '2026-11-10',
    })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(spy).toHaveBeenCalledWith(MORA)
  })
})

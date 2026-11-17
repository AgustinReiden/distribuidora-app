/**
 * 1544-b1 (#1544): crear o anular una nota de crédito de venta mueve la deuda de la boleta, y la
 * lista de deudores en mora (`['deudores-mora']`) quedaba vieja: `useInvalidarTrasNC` invalidaba las
 * notas, los clientes y los pedidos, no la mora.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (...a: unknown[]) => {
      const promesa = Promise.resolve(rpc(...a))
      return Object.assign(promesa, { abortSignal: () => promesa })
    },
  },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import {
  useCrearNotaCreditoVentaMutation,
  useAnularNotaCreditoVentaMutation,
} from './useNotasCreditoVentaQuery'

function montar<T>(hook: () => T) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  const spy = vi.spyOn(qc, 'invalidateQueries')
  const { result } = renderHook(hook, {
    wrapper: ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    ),
  })
  return { result, spy }
}

beforeEach(() => {
  rpc.mockReset()
})

describe('notas de crédito de venta — la mora (1544-b1)', () => {
  it('crear una nota invalida la mora, además de las notas, los clientes y los pedidos', async () => {
    rpc.mockResolvedValue({ data: { nota_credito_id: 1, pago_id: 2, total: 100, fecha: '2026-11-10' }, error: null })
    const { result, spy } = montar(() => useCrearNotaCreditoVentaMutation())

    result.current.mutate({
      pedidoId: '9', clienteId: '5', items: [{ pedido_item_id: 1, cantidad: 1 }],
      motivo: 'producto_vencido', clientRequestId: 'r1',
    } as Parameters<typeof result.current.mutate>[0])

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(spy).toHaveBeenCalledWith({ queryKey: ['deudores-mora'] })
    expect(spy).toHaveBeenCalledWith({ queryKey: ['notas_credito_venta'] })
    expect(spy).toHaveBeenCalledWith({ queryKey: ['clientes'] })
    expect(spy).toHaveBeenCalledWith({ queryKey: ['pedidos'] })
  })

  it('anular una nota invalida la mora', async () => {
    rpc.mockResolvedValue({ data: { success: true }, error: null })
    const { result, spy } = montar(() => useAnularNotaCreditoVentaMutation())

    result.current.mutate({ notaCreditoId: '4', motivo: 'error de carga' })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(spy).toHaveBeenCalledWith({ queryKey: ['deudores-mora'] })
  })
})

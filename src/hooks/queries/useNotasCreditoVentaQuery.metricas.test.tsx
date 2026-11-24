/**
 * REP-1 (tanda 6 de #1603): el Dashboard es neto de notas de crédito de venta, así que emitir o
 * anular una nota tiene que invalidar las métricas: «Venta entregada» quedaba vieja hasta 2 minutos.
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

beforeEach(() => { rpc.mockReset() })

describe('notas de crédito de venta — las métricas del Dashboard (REP-1)', () => {
  it('emitir una nota invalida las métricas', async () => {
    rpc.mockResolvedValue({ data: { nota_credito_id: 1, pago_id: 2, total: 100, fecha: '2026-11-10' }, error: null })
    const { result, spy } = montar(() => useCrearNotaCreditoVentaMutation())

    result.current.mutate({
      pedidoId: '9', clienteId: '5', items: [{ pedido_item_id: 1, cantidad: 1 }],
      motivo: 'producto_vencido', clientRequestId: 'r1',
    } as Parameters<typeof result.current.mutate>[0])

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(spy).toHaveBeenCalledWith({ queryKey: ['metricas'] })
  })

  it('anular una nota invalida las métricas', async () => {
    rpc.mockResolvedValue({ data: { success: true }, error: null })
    const { result, spy } = montar(() => useAnularNotaCreditoVentaMutation())

    result.current.mutate({ notaCreditoId: '4', motivo: 'error de carga' })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(spy).toHaveBeenCalledWith({ queryKey: ['metricas'] })
  })
})

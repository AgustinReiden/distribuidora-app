/**
 * FRT-2 (#1517): el saldo del cliente quedaba viejo hasta 5 minutos después de
 * cobrar, cancelar o cambiar el comprobante de un pedido.
 *
 * Cobrar, cancelar y anular mueven `saldo_cuenta`, pero esas mutations sólo
 * invalidaban pedidos: el alta siguiente del mismo cliente avisaba una deuda o un
 * saldo a favor que ya no existía, y ese aviso es el que evita cobrar de más
 * (#1503, #1509). `useCrearPedidoMutation` ya lo hacía (#1265).
 *
 * Y el alta tampoco invalidaba los cupos de las promos: el regalo del pedido
 * recién creado gasta cupo y el siguiente alta lo veía sin gastar.
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
  useCambiarTipoFacturaMutation,
  useCrearPedidoMutation,
  usePagosMasivosMutation,
} from './usePedidosQuery'
import { clientesKeys } from './useClientesQuery'
import { promocionesKeys } from './usePromocionesQuery'

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

beforeEach(() => {
  rpc.mockReset()
})

describe('mutations de pedidos — el saldo del cliente (FRT-2)', () => {
  it('cancelar un pedido invalida los clientes de la sucursal', async () => {
    rpc.mockResolvedValue({ data: { success: true }, error: null })
    const { result, spy } = montar(() => useCancelarPedidoMutation())

    result.current.mutate({ pedidoId: '10', motivo: 'El cliente no lo quiso' })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(spy).toHaveBeenCalledWith({ queryKey: clientesKeys.all(1) })
  })

  it('el cobro masivo invalida los clientes de la sucursal', async () => {
    rpc.mockResolvedValue({ data: null, error: null })
    const { result, spy } = montar(() => usePagosMasivosMutation())

    result.current.mutate({ pedidoIds: ['10', '11'], formaPago: 'efectivo', fecha: '2026-11-10' })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(spy).toHaveBeenCalledWith({ queryKey: clientesKeys.all(1) })
  })

  it('cambiar el tipo de factura invalida los clientes de la sucursal', async () => {
    rpc.mockResolvedValue({ data: { success: true }, error: null })
    const { result, spy } = montar(() => useCambiarTipoFacturaMutation())

    result.current.mutate({ pedidoId: '10', tipo: 'ZZ' })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(spy).toHaveBeenCalledWith({ queryKey: clientesKeys.all(1) })
  })
})

describe('useCrearPedidoMutation — los cupos de las promos', () => {
  it('invalida los cupos de la sucursal al crear el pedido', async () => {
    rpc.mockResolvedValue({ data: { success: true, pedido_id: '501' }, error: null })
    const { result, spy } = montar(() => useCrearPedidoMutation())

    result.current.mutate({
      clienteId: '7',
      total: 1000,
      usuarioId: 'u1',
      items: [{ productoId: '3', cantidad: 1, precioUnitario: 1000 }],
    } as Parameters<typeof result.current.mutate>[0])

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    // La misma clave que usa `usePromoCuposQuery`, con y sin pedido: va por prefijo.
    expect(spy).toHaveBeenCalledWith({ queryKey: [...promocionesKeys.all(1), 'cupos'] })
    expect(promocionesKeys.cupos(1, '42').slice(0, 3)).toEqual([...promocionesKeys.all(1), 'cupos'])
  })
})

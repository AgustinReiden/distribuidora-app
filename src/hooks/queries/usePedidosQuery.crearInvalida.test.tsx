/**
 * Un pedido nuevo mueve el `saldo_cuenta` del cliente, pero el alta invalidaba
 * sólo pedidos y productos (#1265): la ficha y el listado de clientes mostraban
 * el saldo de antes hasta cumplir el staleTime. El replay de la cola offline
 * pasa por esta misma mutation, así que también quedaba viejo después de
 * sincronizar.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...args: unknown[]) => rpc(...args) },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCrearPedidoMutation } from './usePedidosQuery'
import { clientesKeys } from './useClientesQuery'

describe('useCrearPedidoMutation', () => {
  it('invalida los clientes de la sucursal al crear el pedido', async () => {
    rpc.mockResolvedValue({ data: { success: true, pedido_id: '501' }, error: null })
    const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
    const spy = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useCrearPedidoMutation(), {
      wrapper: ({ children }: { children: React.ReactNode }) => (
        <QueryClientProvider client={qc}>{children}</QueryClientProvider>
      ),
    })

    result.current.mutate({
      clienteId: '7',
      total: 1000,
      usuarioId: 'u1',
      items: [{ productoId: '3', cantidad: 1, precioUnitario: 1000 }],
    } as Parameters<typeof result.current.mutate>[0])

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(spy).toHaveBeenCalledWith({ queryKey: clientesKeys.all(1) })
  })
})

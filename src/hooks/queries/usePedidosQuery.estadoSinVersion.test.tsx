/**
 * 1595-b6 (#1595): la versión del pedido (`updated_at`, la que compara la edición, #1323)
 * la pone el server. El PATCH de estado mandaba la hora del teléfono como versión: con un
 * reloj atrasado podía reponer una versión vieja y pisar la edición de otro.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const { update } = vi.hoisted(() => {
  const single = vi.fn(() => Promise.resolve({ data: { id: 5 }, error: null }))
  const select = vi.fn(() => ({ single }))
  const eq = vi.fn(() => ({ select }))
  return { update: vi.fn((_: Record<string, unknown>) => ({ eq })) }
})

vi.mock('../supabase/base', () => ({
  supabase: { from: () => ({ update }) },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCambiarEstadoMutation } from './usePedidosQuery'

describe('useCambiarEstadoMutation', () => {
  it('no manda updated_at en el PATCH de estado', async () => {
    const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
    const { result } = renderHook(() => useCambiarEstadoMutation(), {
      wrapper: ({ children }: { children: React.ReactNode }) => (
        <QueryClientProvider client={qc}>{children}</QueryClientProvider>
      ),
    })

    result.current.mutate({ pedidoId: '5', nuevoEstado: 'entregado', retiroDeposito: true } as Parameters<typeof result.current.mutate>[0])

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(update).toHaveBeenCalledTimes(1)
    const enviado = update.mock.calls[0][0]
    expect(enviado).toMatchObject({ estado: 'entregado', retiro_deposito: true })
    expect(enviado).not.toHaveProperty('updated_at')
  })
})

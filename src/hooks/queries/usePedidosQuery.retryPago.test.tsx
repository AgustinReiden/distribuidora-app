/**
 * `queryClient.ts` puso `mutations.retry: false` por default (#576): el
 * predicado viejo miraba `error.status`, que un `PostgrestError` real no
 * tiene, así que la guarda de 4xx nunca frenaba nada y CUALQUIER mutation se
 * reintentaba -- también las no idempotentes, donde un reintento después de
 * un timeout puede duplicar un INSERT que ya había entrado.
 *
 * Las mutations que SÍ son seguras de reintentar -- `crear_pedido_idempotente`
 * (mig 071) y las RPCs de pago con `p_client_request_id` (mig 167) -- declaran
 * su propio `retry` en su `useMutation`. Este test fija que siguen
 * reintentando pese al default global en `false`: el `QueryClient` de acá NO
 * pisa `mutations.retry`, a diferencia del resto de los tests de este
 * archivo, así que lo único en juego es la config del hook.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpc(...args),
    from: () => ({ select: () => ({ eq: () => ({ maybeSingle: vi.fn() }) }) }),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCrearPedidoMutation, usePagosMasivosMutation } from './usePedidosQuery'

/** Lo que supabase-js devuelve REALMENTE ante un blip de red: no lanza, resuelve
 *  con `{ error }` -- un objeto plano, sin `status` (ver retryWithBackoff.test.ts). */
const errorDeRedDeSupabase = {
  data: null,
  error: { message: 'TypeError: Failed to fetch', details: 'TypeError: Failed to fetch', hint: '', code: '' },
}

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

function setup() {
  // Sin `defaultOptions.mutations`: el `retry` en juego es el que declara
  // cada hook, no el default global (que en producción es `false`).
  const qc = new QueryClient()
  return qc
}

describe('mutations de pago — siguen reintentando pese al default global en false', () => {
  beforeEach(() => {
    rpc.mockReset()
  })

  it('useCrearPedidoMutation (crear_pedido_idempotente) reintenta ante un timeout', async () => {
    rpc
      .mockResolvedValueOnce(errorDeRedDeSupabase)
      .mockResolvedValueOnce({ data: { success: true, pedido_id: '5001' }, error: null })

    const qc = setup()
    const { result } = renderHook(() => useCrearPedidoMutation(), { wrapper: makeWrapper(qc) })

    result.current.mutate({
      clienteId: '42',
      items: [{ productoId: '7', cantidad: 3, precioUnitario: 1200 }],
      total: 3600,
      usuarioId: 'user-1',
    })

    await waitFor(() => expect(result.current.isSuccess).toBe(true), { timeout: 10000 })
    expect(rpc).toHaveBeenCalledTimes(2)
    expect(rpc.mock.calls[0][0]).toBe('crear_pedido_idempotente')
    expect(rpc.mock.calls[1][0]).toBe('crear_pedido_idempotente')
  }, 15000)

  it('usePagosMasivosMutation (marcar_pagos_masivo) reintenta ante un timeout', async () => {
    rpc
      .mockResolvedValueOnce(errorDeRedDeSupabase)
      .mockResolvedValueOnce({ data: null, error: null })

    const qc = setup()
    const { result } = renderHook(() => usePagosMasivosMutation(), { wrapper: makeWrapper(qc) })

    result.current.mutate({ pedidoIds: ['1', '2'], formaPago: 'efectivo' })

    await waitFor(() => expect(result.current.isSuccess).toBe(true), { timeout: 10000 })
    expect(rpc).toHaveBeenCalledTimes(2)
    expect(rpc.mock.calls[0][0]).toBe('marcar_pagos_masivo')
    expect(rpc.mock.calls[1][0]).toBe('marcar_pagos_masivo')
    // El mismo `p_client_request_id` en las dos llamadas: es lo que hace que
    // el reintento sea seguro -- la base dedupe por esa clave (mig 167).
    const idPrimerIntento = (rpc.mock.calls[0][1] as { p_client_request_id: string }).p_client_request_id
    const idSegundoIntento = (rpc.mock.calls[1][1] as { p_client_request_id: string }).p_client_request_id
    expect(idSegundoIntento).toBe(idPrimerIntento)
  }, 15000)
})

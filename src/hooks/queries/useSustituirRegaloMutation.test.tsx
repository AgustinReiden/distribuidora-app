/**
 * 1598-b9: la clave de idempotencia de las dos RPCs del regalo sale de `nuevoRequestId`, no de
 * `crypto.randomUUID()` pelado, que no existe fuera de un contexto seguro ni en iOS Safari < 15.4
 * (el reparto corre en teléfonos viejos): la sustitución explotaba con un TypeError.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpcCalls: Array<{ fn: string; args: Record<string, unknown> }> = []

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (fn: string, args: Record<string, unknown>) => {
      rpcCalls.push({ fn, args })
      return Promise.resolve({ data: { success: true, sustitucion_id: '1' }, error: null })
    },
  },
}))

import { useSustituirRegaloMutation, useDividirRegaloMutation } from './useSustituirRegaloMutation'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

function wrapper() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

describe('claves de idempotencia del regalo sin crypto.randomUUID (1598-b9)', () => {
  beforeEach(() => { rpcCalls.length = 0 })
  afterEach(() => { vi.unstubAllGlobals() })

  it('sustituir: sin randomUUID igual manda una clave v4', async () => {
    vi.stubGlobal('crypto', { getRandomValues: (a: Uint8Array) => a.fill(7) })
    const { result } = renderHook(() => useSustituirRegaloMutation(), { wrapper: wrapper() })
    await result.current.mutateAsync({ pedidoItemId: 1, productoNuevoId: 2, cantidadNueva: 3, motivo: 'faltante' } as never)
    await waitFor(() => expect(rpcCalls).toHaveLength(1))
    expect(rpcCalls[0].args.p_client_request_id).toMatch(UUID)
  })

  it('dividir: sin randomUUID igual manda una clave v4', async () => {
    vi.stubGlobal('crypto', { getRandomValues: (a: Uint8Array) => a.fill(7) })
    const { result } = renderHook(() => useDividirRegaloMutation(), { wrapper: wrapper() })
    await result.current.mutateAsync({ pedidoItemId: 1, partes: [{ productoId: 2, cantidad: 3 }] } as never)
    await waitFor(() => expect(rpcCalls).toHaveLength(1))
    expect(rpcCalls[0].args.p_client_request_id).toMatch(UUID)
  })

  it('con la clave que pasa el caller usa esa', async () => {
    const { result } = renderHook(() => useSustituirRegaloMutation(), { wrapper: wrapper() })
    await result.current.mutateAsync({ pedidoItemId: 1, productoNuevoId: 2, cantidadNueva: 3, motivo: 'x', clientRequestId: 'abc' } as never)
    expect(rpcCalls[0].args.p_client_request_id).toBe('abc')
  })
})

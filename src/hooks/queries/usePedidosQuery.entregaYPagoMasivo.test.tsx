/**
 * Tests de `useEntregaYPagoMasivosMutation`.
 *
 * Son dos RPCs sin transacción común: si la segunda falla, la primera ya
 * entró en la base. Lo que importa acá:
 *   1. El orden: entregar corre ANTES que cobrar, porque es el paso que puede
 *      rechazar por el gate de rendición cerrada. Si cobrara primero, un
 *      rechazo de la entrega dejaría cobros ya aplicados sin ninguna entrega.
 *   2. La mutation nunca lanza sobre un fallo parcial: devuelve cuántos
 *      entregaron/cobraron con éxito y cuál paso falló, para que el caller
 *      pueda decir "se cobraron N boletas" en vez de un error mudo.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()
const insert = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpc(...args),
    from: () => ({ insert: (...args: unknown[]) => insert(...args) }),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useEntregaYPagoMasivosMutation } from './usePedidosQuery'

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

function setup() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  const { result } = renderHook(() => useEntregaYPagoMasivosMutation(), {
    wrapper: makeWrapper(qc),
  })
  return { qc, result }
}

describe('useEntregaYPagoMasivosMutation', () => {
  beforeEach(() => {
    rpc.mockReset()
    insert.mockReset()
    insert.mockResolvedValue({ error: null })
  })

  it('si la entrega (primera RPC) falla, no llega a intentar el cobro', async () => {
    rpc.mockResolvedValueOnce({ data: null, error: { message: 'Rendición cerrada' } })
    const { result } = setup()

    result.current.mutate({
      idsEntregar: ['1'], idsCobrar: ['2'],
      transportistaId: 't1', formaPago: 'efectivo', fecha: '2026-09-10',
    })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(rpc).toHaveBeenCalledTimes(1)
    expect(rpc).toHaveBeenCalledWith('marcar_entrega_y_pago_masivo', expect.anything())
    expect(result.current.data).toEqual({
      entregados: 0, cobrados: 0,
      error: { paso: 'entregar', mensaje: 'Rendición cerrada' },
    })
  })

  it('si la entrega funciona pero el cobro (segunda RPC) falla, el resultado dice qué SÍ entró', async () => {
    rpc.mockResolvedValueOnce({ data: null, error: null }) // marcar_entrega_y_pago_masivo
    rpc.mockResolvedValueOnce({ data: null, error: { message: 'Timeout' } }) // marcar_pagos_masivo

    const { result } = setup()
    result.current.mutate({
      idsEntregar: ['1', '2'], idsCobrar: ['3'],
      transportistaId: 't1', formaPago: 'efectivo', fecha: '2026-09-10',
    })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(rpc).toHaveBeenNthCalledWith(1, 'marcar_entrega_y_pago_masivo', expect.anything())
    expect(rpc).toHaveBeenNthCalledWith(2, 'marcar_pagos_masivo', expect.anything())
    expect(result.current.data).toEqual({
      entregados: 2, cobrados: 0,
      error: { paso: 'cobrar', mensaje: 'Timeout' },
    })
  })

  it('sin errores, devuelve los totales de los dos pasos y sin `error`', async () => {
    rpc.mockResolvedValue({ data: null, error: null })
    const { result } = setup()

    result.current.mutate({
      idsEntregar: ['1'], idsCobrar: ['2', '3'],
      transportistaId: 't1', formaPago: 'efectivo', fecha: '2026-09-10',
    })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data).toEqual({ entregados: 1, cobrados: 2 })
  })
})

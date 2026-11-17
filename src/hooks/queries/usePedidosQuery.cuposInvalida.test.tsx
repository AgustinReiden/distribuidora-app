/**
 * 1543-b4: los cupos de una promo (`promocionesKeys.cupos`) sólo se invalidaban al crear un pedido.
 * Cancelar, cambiar de cliente y anular una salvedad (y, desde el container, editar y cargar una
 * salvedad) también liberan o consumen cupo: la pantalla seguía con el de antes hasta 30 s.
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

// El módulo de mermas crea el cliente real al importarse (necesita las env de Vite).
vi.mock('../../lib/supabase', () => ({ supabase: {} }))

import { useCancelarPedidoMutation, useCambiarClientePedidoMutation } from './usePedidosQuery'
import { useAnularSalvedadMutation } from './useAnularSalvedadMutation'
import { invalidarCuposPromo } from './cuposPromoCache'
import { promocionesKeys } from './usePromocionesQuery'

const CLAVE_CUPOS = promocionesKeys.cupos(1, '7')
const CLAVE_LISTA = promocionesKeys.lists(1)

function montar<T>(hook: () => T) {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false }, queries: { staleTime: 60_000 } } })
  qc.setQueryData(CLAVE_CUPOS, [{ promoId: 'p1', restante: 3 }])
  qc.setQueryData(CLAVE_LISTA, [])
  const r = renderHook(hook, {
    wrapper: ({ children }: { children: React.ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>,
  })
  return { qc, ...r }
}

const cuposViejos = (qc: QueryClient) => qc.getQueryState(CLAVE_CUPOS)?.isInvalidated === true

describe('los cupos de promo se invalidan cuando el pedido cambia (1543-b4)', () => {
  it('invalidarCuposPromo toca los cupos y no las otras consultas de promociones', async () => {
    const { qc } = montar(() => null)
    await invalidarCuposPromo(qc)
    expect(cuposViejos(qc)).toBe(true)
    expect(qc.getQueryState(CLAVE_LISTA)?.isInvalidated).toBe(false)
  })

  it('cancelar un pedido', async () => {
    rpc.mockResolvedValue({ data: { success: true }, error: null })
    const { qc, result } = montar(() => useCancelarPedidoMutation())
    result.current.mutate({ pedidoId: '9', motivo: 'x' })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(cuposViejos(qc)).toBe(true)
  })

  it('cambiar el cliente de un pedido', async () => {
    rpc.mockResolvedValue({ data: { success: true, nuevo_pedido_id: '10' }, error: null })
    const { qc, result } = montar(() => useCambiarClientePedidoMutation())
    result.current.mutate({ pedidoId: '9', nuevoClienteId: '2', usuarioId: 'u', items: [], total: 0 } as never)
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(cuposViejos(qc)).toBe(true)
  })

  it('anular una salvedad', async () => {
    rpc.mockResolvedValue({ data: { success: true }, error: null })
    const { qc, result } = montar(() => useAnularSalvedadMutation())
    result.current.mutate({ salvedadId: '4', notas: 'x' })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(cuposViejos(qc)).toBe(true)
  })
})

/**
 * Tests del contrato de la anulacion de salvedades (mig 244, decision #621).
 *
 * EL BUG: habia dos caminos para "anular" y hacian cosas distintas.
 * `resolver_salvedad(id, 'anulada')` --lo que disparaba el picker-- sólo
 * escribia el estado: la linea del pedido seguia recortada, la plata seguia
 * sin cobrarse y la merma por dañado/vencido seguia viva. Y encima trababa al
 * `anular_salvedad` de verdad para siempre ("Ya anulada").
 *
 * Lo que fijan estos tests es la mitad del cliente: que la anulacion viaje por
 * su propia RPC y que una negativa de negocio --que el RPC devuelve con HTTP
 * 200 y `success: false`-- llegue como Error y no como exito silencioso. La
 * otra mitad --restituir la linea, recalcular totales, anular la merma-- vive
 * en la mig 244 y la verifica su propio ensayo contra la base.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpcCalls: Array<{ fn: string; args: Record<string, unknown> }> = []
let rpcResult: { data: unknown; error: { message: string } | null } = {
  data: { success: true },
  error: null,
}

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (fn: string, args: Record<string, unknown>) => {
      rpcCalls.push({ fn, args })
      return Promise.resolve(rpcResult)
    },
    from: (tabla: string) => {
      throw new Error(`la anulacion no deberia tocar la tabla ${tabla}`)
    },
  },
}))

// El hook importa `mermasReporteKeys` para invalidar el reporte de mermas, y ese
// modulo crea el cliente real al importarse (necesita las env de Vite, que en la
// corrida sin `.env` no estan). Se mockea el cliente, no la clave.
vi.mock('../../lib/supabase', () => ({ supabase: {} }))

import { useAnularSalvedadMutation } from './useAnularSalvedadMutation'

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

function setup() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  return renderHook(() => useAnularSalvedadMutation(), { wrapper: makeWrapper(qc) })
}

describe('anular una salvedad — contrato con el servidor', () => {
  beforeEach(() => {
    rpcCalls.length = 0
    rpcResult = { data: { success: true }, error: null }
  })

  it('llama a anular_salvedad, no a resolver_salvedad', async () => {
    const { result } = setup()

    await result.current.mutateAsync({ salvedadId: '42', notas: 'se cargó por error' })

    await waitFor(() => expect(rpcCalls).toHaveLength(1))
    expect(rpcCalls[0].fn).toBe('anular_salvedad')
    expect(rpcCalls[0].args).toEqual({ p_salvedad_id: 42, p_notas: 'se cargó por error' })
  })

  it('el id viaja como number: los ids son bigint y llegan como number en runtime', async () => {
    const { result } = setup()

    await result.current.mutateAsync({ salvedadId: '907', notas: 'llegó bien la mercadería' })

    expect(rpcCalls[0].args.p_salvedad_id).toBe(907)
  })

  it('una negativa de negocio (success:false con HTTP 200) sube como Error', async () => {
    rpcResult = {
      data: {
        success: false,
        error: 'Esta salvedad es sobre un regalo de promocion.',
        codigo: 'anulacion_toca_promociones',
      },
      error: null,
    }
    const { result } = setup()

    await expect(
      result.current.mutateAsync({ salvedadId: '42', notas: 'probando' }),
    ).rejects.toThrow('Esta salvedad es sobre un regalo de promocion.')
  })

  it('un error de transporte tambien rechaza', async () => {
    rpcResult = { data: null, error: { message: 'network down' } }
    const { result } = setup()

    await expect(
      result.current.mutateAsync({ salvedadId: '42', notas: 'probando' }),
    ).rejects.toThrow('network down')
  })
})

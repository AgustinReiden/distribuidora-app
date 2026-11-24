/**
 * FRV-1 (tanda 6 de #1603): el alta de un cliente manda «No atiende con horario fijo».
 *
 * `createCliente` arma los campos de la RPC uno por uno y se había quedado sin
 * `sin_horario_fijo`: el formulario lo mandaba, el server lo acepta, y el cliente nacía con
 * el horario exigido (el botón Confirmar de «Nuevo pedido» quedaba trabado hasta completar
 * el bloque «horario requerido»). La edición arma el patch por spread y siempre lo mandó.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { SIN_DUPLICADO_RPC_TEST } from '../../test/guardarClienteSimulado'

const m = vi.hoisted(() => ({ rpcs: [] as Array<{ fn: string; args: Record<string, unknown> }> }))

vi.mock('../supabase/base', () => ({
  supabase: {
    from: () => {
      const b: Record<string, unknown> = {}
      for (const op of ['select', 'eq', 'in', 'insert', 'update', 'delete']) b[op] = () => b
      b.maybeSingle = () => Promise.resolve({ data: null, error: null })
      b.then = (ok: (r: unknown) => unknown) => ok({ data: [], error: null })
      return b
    },
    rpc: (fn: string, args: Record<string, unknown>) => {
      m.rpcs.push({ fn, args })
      if (fn === 'guardar_cliente') {
        return Promise.resolve({
          data: { success: true, replay: false, cliente: { id: 77, nombre_fantasia: 'K' }, preventista_ids: [] },
          error: null,
        })
      }
      return Promise.resolve({ data: SIN_DUPLICADO_RPC_TEST, error: null })
    },
  },
}))
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))

import { useCrearClienteMutation, useActualizarClienteMutation } from './useClientesQuery'

function wrapper({ children }: { children: React.ReactNode }): React.ReactElement {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

const camposGuardados = (): Record<string, unknown> =>
  (m.rpcs.find(r => r.fn === 'guardar_cliente')!.args.p_cliente as { campos: Record<string, unknown> }).campos

beforeEach(() => { m.rpcs = [] })

describe('FRV-1: «No atiende con horario fijo» viaja en el alta', () => {
  it('el alta tildada manda sin_horario_fijo = true', async () => {
    const { result } = renderHook(() => useCrearClienteMutation(), { wrapper })
    await result.current.mutateAsync({
      razon_social: 'K', nombre_fantasia: 'K', direccion: 'B 1', sin_horario_fijo: true,
      clave: '00000000-0000-4000-8000-000000000001',
    })
    expect(camposGuardados()).toHaveProperty('sin_horario_fijo', true)
  })

  it('el alta sin tildar manda false (no deja la columna sin escribir)', async () => {
    const { result } = renderHook(() => useCrearClienteMutation(), { wrapper })
    await result.current.mutateAsync({
      razon_social: 'K', nombre_fantasia: 'K', direccion: 'B 1',
      clave: '00000000-0000-4000-8000-000000000002',
    })
    expect(camposGuardados()).toHaveProperty('sin_horario_fijo', false)
  })

  it('la edición sigue mandándolo', async () => {
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })
    await result.current.mutateAsync({ id: '77', data: { sin_horario_fijo: true } })
    expect(camposGuardados()).toHaveProperty('sin_horario_fijo', true)
  })
})

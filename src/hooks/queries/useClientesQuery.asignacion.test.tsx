/**
 * La ficha guarda sólo lo que cambió de la asignación (#1316, ASG-7), ahora dentro de
 * `guardar_cliente` (C4b v2 de #1603).
 *
 * La regla no cambió: con `preventista_ids_previos` (lo que el formulario cargó) se escribe la
 * diferencia contra eso, y sin previos (el alta, o una edición que cambia la zona o libera un
 * reservado) la lista del formulario reemplaza lo que haya en la base. Lo que cambió es dónde se
 * hace: en la misma transacción que el cliente, en el server (lo prueba el ensayo
 * scripts/test-guardados-atomicos-ola2-1603.sql, K6 y K7). Acá se fija lo que manda el front: la
 * lista y los previos tal cual, sin escribir `cliente_preventistas` por REST.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { simularGuardarCliente } from '../../test/guardarClienteSimulado'

const escriturasRest = vi.fn()
const rpcSimulado = simularGuardarCliente()

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (tabla: string) => {
      const b: Record<string, unknown> = {}
      for (const op of ['insert', 'update', 'delete', 'upsert']) b[op] = () => { escriturasRest(tabla, op); return b }
      for (const op of ['select', 'eq', 'in']) b[op] = () => b
      b.maybeSingle = () => Promise.resolve({ data: null, error: null })
      b.then = (ok: (r: unknown) => unknown) => ok({ data: [], error: null })
      return b
    },
    rpc: (...args: unknown[]) => rpcSimulado(...(args as [string, Record<string, unknown>])),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCrearClienteMutation, useActualizarClienteMutation } from './useClientesQuery'

function wrapper({ children }: { children: React.ReactNode }): React.ReactElement {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

function enviado(): Record<string, unknown> {
  const llamada = rpcSimulado.mock.calls.find(([fn]) => fn === 'guardar_cliente')
  return (llamada?.[1] as { p_cliente: Record<string, unknown> }).p_cliente
}

describe('asignación de preventistas: viaja en el mismo guardado (#1316, C4b v2)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('con previos, manda la lista y los previos tal cual (el server escribe sólo la diferencia)', async () => {
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })

    await result.current.mutateAsync({
      id: '77',
      data: { notas: 'x', preventista_ids: ['p-b', 'p-c'], preventista_ids_previos: ['p-a', 'p-b'] },
    })

    expect(enviado()).toMatchObject({ id: 77, preventista_ids: ['p-b', 'p-c'], preventista_ids_previos: ['p-a', 'p-b'] })
    expect(escriturasRest).not.toHaveBeenCalled()
  })

  it('sin previos (cambió la zona o liberó un reservado), no los manda: la lista reemplaza lo que haya', async () => {
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })

    await result.current.mutateAsync({ id: '77', data: { zona_id: '6', preventista_ids: ['p-pedro'] } })

    expect(enviado()).toMatchObject({ preventista_ids: ['p-pedro'] })
    expect(enviado()).not.toHaveProperty('preventista_ids_previos')
  })

  it('sin tocar la asignación no manda la lista (ni los previos)', async () => {
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })

    await result.current.mutateAsync({ id: '77', data: { notas: 'x' } })

    expect(enviado()).not.toHaveProperty('preventista_ids')
    expect(enviado()).not.toHaveProperty('preventista_ids_previos')
  })

  it('el cache queda con la asignación que devolvió el server', async () => {
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })

    const actualizado = await result.current.mutateAsync({ id: '77', data: { preventista_ids: ['p-b'], preventista_ids_previos: [] } })

    expect(actualizado.preventista_ids).toEqual(['p-b'])
  })

  it('en el alta manda la lista sin previos (el server compara contra la base: el dueño de la zona que puso el trigger)', async () => {
    const { result } = renderHook(() => useCrearClienteMutation(), { wrapper })

    await result.current.mutateAsync({
      razon_social: 'Kiosco', nombre_fantasia: 'Kiosco', direccion: 'Belgrano 1', zona_id: '5',
      preventista_ids: ['p-duenio'], clave: '00000000-0000-4000-8000-000000000009',
    })

    expect(enviado()).toMatchObject({ clave: '00000000-0000-4000-8000-000000000009', preventista_ids: ['p-duenio'] })
    expect(enviado()).not.toHaveProperty('preventista_ids_previos')
    expect(escriturasRest).not.toHaveBeenCalled()
  })
})

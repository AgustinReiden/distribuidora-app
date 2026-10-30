/**
 * La ficha guarda sólo lo que cambió de la asignación (#1316, ASG-7).
 *
 * Antes `updateCliente` borraba todas las filas de `cliente_preventistas` y
 * volvía a insertar la lista del formulario. Si mientras la ficha estaba
 * abierta el admin linkeaba la zona del cliente a otro preventista, guardar la
 * ficha (aunque no se tocara la asignación) reponía al preventista viejo.
 *
 * Ahora compara contra lo que el formulario cargó (`preventista_ids_previos`):
 * sin cambios no escribe nada; con cambios borra sólo lo que se sacó y agrega
 * sólo lo que se sumó (una que ya está, 23505, no es error). En el alta compara
 * contra la base, porque el trigger de la zona ya pudo haber asignado al dueño.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const llamadas = vi.fn()
const from = vi.fn()

const SIN_DUPLICADO = {
  bloquea: false, avisa: false, motivo: null, distancia_m: null, cliente_visible: null,
}

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (...args: unknown[]) => from(...args),
    rpc: () => Promise.resolve({ data: SIN_DUPLICADO, error: null }),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCrearClienteMutation, useActualizarClienteMutation } from './useClientesQuery'

let asignadasEnBase: string[] = []

function montarSupabase(): void {
  from.mockImplementation((tabla: string) => {
    if (tabla === 'clientes') {
      const builder: Record<string, unknown> = {}
      builder.insert = () => builder
      builder.update = () => builder
      builder.select = () => builder
      builder.eq = () => builder
      builder.single = () => Promise.resolve({ data: { id: '77', nombre_fantasia: 'Kiosco' }, error: null })
      return builder
    }
    let op = ''
    const builder: Record<string, unknown> = {}
    builder.select = () => { op = 'select'; llamadas(tabla, 'select'); return builder }
    builder.delete = () => { op = 'delete'; return builder }
    builder.eq = () => builder
    builder.in = (col: string, vals: string[]) => { llamadas(tabla, 'delete', col, vals); return builder }
    builder.then = (resolve: (r: unknown) => unknown) =>
      resolve(op === 'select'
        ? { data: asignadasEnBase.map(preventista_id => ({ preventista_id })), error: null }
        : { error: null })
    builder.insert = (fila: { preventista_id?: string }) => {
      llamadas(tabla, 'insert', fila)
      // Ya asignado (el trigger o un link concurrente): la base contesta 23505.
      return Promise.resolve({ error: fila.preventista_id && asignadasEnBase.includes(fila.preventista_id) ? { code: '23505', message: 'duplicate key' } : null })
    }
    return builder
  })
}

function wrapper({ children }: { children: React.ReactNode }): React.ReactElement {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

const escrituras = () =>
  llamadas.mock.calls.filter(([tabla, op]) => tabla === 'cliente_preventistas' && op !== 'select')

describe('asignación de preventistas: se guarda la diferencia (#1316)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    asignadasEnBase = []
    montarSupabase()
  })

  it('sin tocar la asignación no escribe nada, aunque la base ya tenga otro preventista', async () => {
    // El admin linkeó la zona a "p-nuevo" mientras la ficha (que cargó "p-viejo") estaba abierta.
    asignadasEnBase = ['p-nuevo']
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })

    const actualizado = await result.current.mutateAsync({
      id: '77',
      data: { notas: 'x', preventista_ids: ['p-viejo'], preventista_ids_previos: ['p-viejo'] },
    })

    expect(escrituras()).toEqual([])
    // El cache queda con lo que hay en la base, no con lo que tenía la ficha.
    expect(actualizado.preventista_ids).toEqual(['p-nuevo'])
  })

  it('sin previos (cambió la zona o liberó un reservado), la lista del formulario reemplaza lo que puso el trigger', async () => {
    // El UPDATE de zona_id ya asignó al dueño de la zona nueva; el admin eligió a Pedro.
    asignadasEnBase = ['p-duenio']
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })

    await result.current.mutateAsync({ id: '77', data: { zona_id: '6', preventista_ids: ['p-pedro'] } })

    expect(escrituras()).toEqual([
      ['cliente_preventistas', 'delete', 'preventista_id', ['p-duenio']],
      ['cliente_preventistas', 'insert', { cliente_id: '77', preventista_id: 'p-pedro' }],
    ])
  })

  it('sumar a uno que ya está asignado (23505) no es un error', async () => {
    // La ficha cargó sin nadie; mientras tanto el link de zona lo asignó a "p-b".
    asignadasEnBase = ['p-b']
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })

    const actualizado = await result.current.mutateAsync({
      id: '77',
      data: { preventista_ids: ['p-b'], preventista_ids_previos: [] },
    })

    expect(escrituras()).toEqual([['cliente_preventistas', 'insert', { cliente_id: '77', preventista_id: 'p-b' }]])
    expect(actualizado.preventista_ids).toEqual(['p-b'])
  })

  it('cambiar de preventista borra sólo al que se sacó y agrega sólo al que se sumó', async () => {
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })

    await result.current.mutateAsync({
      id: '77',
      data: { preventista_ids: ['p-b', 'p-c'], preventista_ids_previos: ['p-a', 'p-b'] },
    })

    expect(escrituras()).toEqual([
      ['cliente_preventistas', 'delete', 'preventista_id', ['p-a']],
      ['cliente_preventistas', 'insert', { cliente_id: '77', preventista_id: 'p-c' }],
    ])
  })

  it('en el alta compara contra la base: si el trigger ya puso al dueño de la zona, no lo vuelve a insertar', async () => {
    asignadasEnBase = ['p-duenio']
    const { result } = renderHook(() => useCrearClienteMutation(), { wrapper })

    await result.current.mutateAsync({
      razon_social: 'Kiosco', nombre_fantasia: 'Kiosco', direccion: 'Belgrano 1', zona_id: '5',
      preventista_ids: ['p-duenio'],
    })

    expect(escrituras()).toEqual([])
  })

  it('en el alta, el admin que destilda al dueño de la zona lo saca', async () => {
    asignadasEnBase = ['p-duenio']
    const { result } = renderHook(() => useCrearClienteMutation(), { wrapper })

    await result.current.mutateAsync({
      razon_social: 'Kiosco', nombre_fantasia: 'Kiosco', direccion: 'Belgrano 1', zona_id: '5',
      preventista_ids: [],
    })

    expect(escrituras()).toEqual([['cliente_preventistas', 'delete', 'preventista_id', ['p-duenio']]])
  })
})

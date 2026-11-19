/**
 * El alta y la edición de un cliente en UNA llamada (`guardar_cliente`, C4b v2 de #1603; también
 * 1598-b5: los descuentos por categoría van en la misma transacción).
 *
 * Antes eran el INSERT o el PATCH de `clientes`, `cliente_preventistas` (un DELETE y un INSERT por
 * preventista) y los descuentos (un INSERT, un DELETE y otro INSERT), en llamadas REST separadas.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { SIN_DUPLICADO_RPC_TEST } from '../../test/guardarClienteSimulado'

const m = vi.hoisted(() => ({
  escriturasRest: [] as string[],
  rpcs: [] as Array<{ fn: string; args: Record<string, unknown> }>,
  respuesta: null as unknown,
}))

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (tabla: string) => {
      const b: Record<string, unknown> = {}
      for (const op of ['insert', 'update', 'delete', 'upsert']) b[op] = () => { m.escriturasRest.push(`${tabla}.${op}`); return b }
      for (const op of ['select', 'eq', 'in']) b[op] = () => b
      b.maybeSingle = () => Promise.resolve({ data: null, error: null })
      b.then = (ok: (r: unknown) => unknown) => ok({ data: [], error: null })
      return b
    },
    rpc: (fn: string, args: Record<string, unknown>) => {
      m.rpcs.push({ fn, args })
      if (fn === 'guardar_cliente') return Promise.resolve(m.respuesta)
      return Promise.resolve({ data: SIN_DUPLICADO_RPC_TEST, error: null })
    },
  },
}))
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))

import { useCrearClienteMutation, useActualizarClienteMutation } from './useClientesQuery'
import { ConflictoDeVersionError } from '../../utils/conflictoDeVersion'

function wrapper({ children }: { children: React.ReactNode }): React.ReactElement {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

const guardado = () => m.rpcs.find(r => r.fn === 'guardar_cliente')?.args.p_cliente as Record<string, unknown>

beforeEach(() => {
  m.escriturasRest = []
  m.rpcs = []
  m.respuesta = { data: { success: true, replay: false, cliente: { id: 77, nombre_fantasia: 'Kiosco' }, preventista_ids: ['p1'] }, error: null }
})

describe('guardar un cliente en una sola llamada (C4b v2)', () => {
  it('el alta manda la clave, los campos, los preventistas y los descuentos juntos, sin escrituras REST', async () => {
    const { result } = renderHook(() => useCrearClienteMutation(), { wrapper })

    const cliente = await result.current.mutateAsync({
      razon_social: 'Kiosco', nombre_fantasia: 'Kiosco', direccion: 'Belgrano 1',
      preventista_ids: ['p1'], descuentos_categoria: [{ categoria: 'Bebidas', descuento_porcentaje: 7 }],
      clave: '00000000-0000-4000-8000-000000000001',
    })

    expect(m.escriturasRest).toEqual([])
    expect(guardado()).toMatchObject({
      clave: '00000000-0000-4000-8000-000000000001',
      campos: { razon_social: 'Kiosco', nombre_fantasia: 'Kiosco', direccion: 'Belgrano 1', dias_credito: 30 },
      preventista_ids: ['p1'],
      descuentos_categoria: [{ categoria: 'Bebidas', descuento_porcentaje: 7 }],
    })
    expect(guardado().campos).not.toHaveProperty('sucursal_id')
    expect(cliente.preventista_ids).toEqual(['p1'])
  })

  it('la edición manda el id y la versión que se abrió', async () => {
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })

    await result.current.mutateAsync({ id: '77', data: { notas: 'x', updated_at_esperado: '2026-11-18T10:00:00.123456+00:00' } })

    expect(guardado()).toMatchObject({ id: 77, updated_at_esperado: '2026-11-18T10:00:00.123456+00:00', campos: { notas: 'x' } })
    expect(guardado().campos).not.toHaveProperty('updated_at_esperado')
    expect(m.escriturasRest).toEqual([])
  })

  it('si otro lo cambió, rechaza con un ConflictoDeVersionError que dice que lo cargado sigue en la ventana', async () => {
    m.respuesta = { data: { success: false, codigo: 'cliente_cambiado', error: 'Otro usuario cambió este cliente mientras lo editabas: no se guardó nada.' }, error: null }
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })

    const error = await result.current.mutateAsync({ id: '77', data: { notas: 'x', updated_at_esperado: 'v' } })
      .then(() => null, (e: unknown) => e as Error)

    expect(error).toBeInstanceOf(ConflictoDeVersionError)
    expect(error?.message).toContain('Lo que cargaste sigue en esta ventana')
  })

  it('un rechazo del server (una guarda de la base) llega con su motivo', async () => {
    m.respuesta = { data: null, error: { code: '42501', message: 'Sólo un administrador puede cambiar descuento, límite o días de crédito de un cliente' } }
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })

    await expect(result.current.mutateAsync({ id: '77', data: { limite_credito: 5 } }))
      .rejects.toThrow('Sólo un administrador puede cambiar descuento')
  })

  it('sin respuesta en el alta, dice que se puede volver a guardar sin duplicarlo', async () => {
    m.respuesta = { data: null, error: { code: '', message: 'TypeError: Failed to fetch' } }
    const { result } = renderHook(() => useCrearClienteMutation(), { wrapper })

    await expect(result.current.mutateAsync({ razon_social: 'K', nombre_fantasia: 'K', direccion: 'B 1' }))
      .rejects.toThrow(/si ya había entrado, no se crea otro/)
  })
})

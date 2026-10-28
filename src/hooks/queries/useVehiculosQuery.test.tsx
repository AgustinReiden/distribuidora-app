import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

type ErrorDeSupabase = { message: string; details?: string; hint?: string; code: string }

const rpcCalls: Array<{ fn: string; args: Record<string, unknown> }> = []
const chainCalls: Array<{ method: string; args: unknown[] }> = []
let rpcResult: { data: unknown; error: ErrorDeSupabase | null } = { data: 3, error: null }

function crearCadena() {
  const cadena: Record<string, unknown> = {}
  for (const metodo of ['select', 'eq', 'order']) {
    cadena[metodo] = (...args: unknown[]) => {
      chainCalls.push({ method: metodo, args })
      return cadena
    }
  }
  cadena.then = (resolve: (v: unknown) => unknown) => Promise.resolve({ data: [], error: null }).then(resolve)
  return cadena
}

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (fn: string, args: Record<string, unknown>) => {
      rpcCalls.push({ fn, args })
      return Promise.resolve(rpcResult)
    },
    from: () => crearCadena(),
    auth: { getUser: vi.fn() },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import {
  useVehiculosQuery,
  useGuardarVehiculoMutation,
  useRegistrarKmMutation,
} from './useVehiculosQuery'

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

const nuevoCliente = () =>
  new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })

beforeEach(() => {
  rpcCalls.length = 0
  chainCalls.length = 0
  rpcResult = { data: 3, error: null }
})

describe('useGuardarVehiculoMutation', () => {
  it('manda el vehículo a guardar_vehiculo y devuelve el id', async () => {
    const { result } = renderHook(() => useGuardarVehiculoMutation(), { wrapper: makeWrapper(nuevoCliente()) })

    const id = await result.current.mutateAsync({ patente: 'AC456EF', descripcion: 'Partner' })

    expect(id).toBe(3)
    expect(rpcCalls).toEqual([
      { fn: 'guardar_vehiculo', args: { p_vehiculo: { patente: 'AC456EF', descripcion: 'Partner' } } },
    ])
  })

  it('el mensaje del server llega a la UI', async () => {
    rpcResult = { data: null, error: { message: 'Ya existe un vehículo con esa patente', code: 'P0001' } }
    const { result } = renderHook(() => useGuardarVehiculoMutation(), { wrapper: makeWrapper(nuevoCliente()) })

    const error = await result.current.mutateAsync({ patente: 'AC456EF', descripcion: 'Partner' }).catch((e: unknown) => e)

    expect((error as Error).message).toBe('Ya existe un vehículo con esa patente')
  })
})

describe('useRegistrarKmMutation', () => {
  it('manda vehículo, fecha y km a registrar_km_vehiculo', async () => {
    const { result } = renderHook(() => useRegistrarKmMutation(), { wrapper: makeWrapper(nuevoCliente()) })

    await result.current.mutateAsync({ vehiculoId: 3, fecha: '2026-10-28', km: 184230 })

    expect(rpcCalls).toEqual([
      { fn: 'registrar_km_vehiculo', args: { p_vehiculo_id: 3, p_fecha: '2026-10-28', p_km: 184230 } },
    ])
  })
})

describe('useVehiculosQuery', () => {
  it('por defecto trae sólo los activos, ordenados por patente', async () => {
    const { result } = renderHook(() => useVehiculosQuery(), { wrapper: makeWrapper(nuevoCliente()) })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    const llamadas = chainCalls.map(c => [c.method, ...c.args])
    expect(llamadas).toContainEqual(['eq', 'activo', true])
    expect(llamadas).toContainEqual(['order', 'patente'])
  })

  it('con incluirInactivos no filtra por activo', async () => {
    const { result } = renderHook(() => useVehiculosQuery({ incluirInactivos: true }), { wrapper: makeWrapper(nuevoCliente()) })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(chainCalls.some(c => c.method === 'eq')).toBe(false)
  })
})

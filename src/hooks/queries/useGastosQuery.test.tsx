/**
 * Contrato de los hooks de gastos con el servidor (entrega 1).
 *
 * Las escrituras van SIEMPRE por RPC (no hay escritura REST sobre `gastos`) y
 * el mes se lee con la ventana `mes_imputado <= mes <= mes_fin`, sin anulados.
 * Los mocks de supabase siguen la forma real: el error es un objeto plano.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

type ErrorDeSupabase = { message: string; details?: string; hint?: string; code: string }

const rpcCalls: Array<{ fn: string; args: Record<string, unknown> }> = []
const chainCalls: Array<{ method: string; args: unknown[] }> = []
const fromCalls: string[] = []
let rpcResult: { data: unknown; error: ErrorDeSupabase | null } = { data: 41, error: null }
/** Lo que devuelve `from(tabla)`; lo que no está, una lista vacía. */
let datosPorTabla: Record<string, unknown> = {}

/** `from(...)` encadenable: registra cada llamada y se puede esperar (`await`). */
function crearCadena(resultado: { data: unknown; error: ErrorDeSupabase | null }) {
  const cadena: Record<string, unknown> = {}
  for (const metodo of ['select', 'lte', 'gte', 'is', 'eq', 'in', 'order', 'maybeSingle']) {
    cadena[metodo] = (...args: unknown[]) => {
      chainCalls.push({ method: metodo, args })
      return cadena
    }
  }
  cadena.then = (resolve: (v: unknown) => unknown) => Promise.resolve(resultado).then(resolve)
  return cadena
}

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (fn: string, args: Record<string, unknown>) => {
      rpcCalls.push({ fn, args })
      return Promise.resolve(rpcResult)
    },
    from: (tabla: string) => {
      fromCalls.push(tabla)
      return crearCadena({ data: tabla in datosPorTabla ? datosPorTabla[tabla] : [], error: null })
    },
    auth: { getUser: vi.fn() },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import {
  useGastosDelMesQuery,
  useGuardarGastoMutation,
  useAnularGastoMutation,
  useKmDelGastoQuery,
  useRendicionesCerradasQuery,
  gastosKeys,
} from './useGastosQuery'
import type { GuardarGastoPayload } from '../../types/gastos'

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

function nuevoCliente() {
  return new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
}

const PAYLOAD: GuardarGastoPayload = {
  fecha: '2026-10-28',
  rubro_id: 5,
  monto_total: 8500,
  comprobante: 'ticket',
  sucursal_id: 1,
  compartido: false,
  mes_imputado: '2026-10-01',
  repartir_meses: 1,
  origen_pago: 'oficina',
}

beforeEach(() => {
  rpcCalls.length = 0
  chainCalls.length = 0
  fromCalls.length = 0
  datosPorTabla = {}
  rpcResult = { data: 41, error: null }
})

describe('useGuardarGastoMutation', () => {
  it('manda el payload tal cual a guardar_gasto y devuelve el id', async () => {
    const { result } = renderHook(() => useGuardarGastoMutation(), { wrapper: makeWrapper(nuevoCliente()) })

    const id = await result.current.mutateAsync(PAYLOAD)

    expect(id).toBe(41)
    expect(rpcCalls).toEqual([{ fn: 'guardar_gasto', args: { p_gasto: PAYLOAD } }])
    expect(fromCalls).toEqual([])
  })

  it('un error plano de supabase termina en un Error con el mensaje del server', async () => {
    rpcResult = {
      data: null,
      error: { message: 'Sólo un admin puede cargar un gasto compartido', code: 'P0001' },
    }
    const { result } = renderHook(() => useGuardarGastoMutation(), { wrapper: makeWrapper(nuevoCliente()) })

    const error = await result.current.mutateAsync({ ...PAYLOAD, compartido: true }).catch((e: unknown) => e)

    expect(error).toBeInstanceOf(Error)
    expect((error as Error).message).toBe('Sólo un admin puede cargar un gasto compartido')
  })

  it('invalida los gastos y los vehículos de la sucursal', async () => {
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useGuardarGastoMutation(), { wrapper: makeWrapper(qc) })

    await result.current.mutateAsync(PAYLOAD)

    await waitFor(() => expect(invalidar).toHaveBeenCalledTimes(2))
    const keys = invalidar.mock.calls.map(c => (c[0] as { queryKey: unknown[] }).queryKey)
    expect(keys).toContainEqual(['gastos', 1])
    expect(keys).toContainEqual(['vehiculos', 1])
  })
})

describe('useAnularGastoMutation', () => {
  it('manda el id y el motivo a anular_gasto', async () => {
    rpcResult = { data: null, error: null }
    const { result } = renderHook(() => useAnularGastoMutation(), { wrapper: makeWrapper(nuevoCliente()) })

    await result.current.mutateAsync({ id: 7, motivo: 'Cargado dos veces' })

    expect(rpcCalls).toEqual([
      { fn: 'anular_gasto', args: { p_gasto_id: 7, p_motivo: 'Cargado dos veces' } },
    ])
  })

  it('el rechazo del server llega como Error con su mensaje', async () => {
    rpcResult = { data: null, error: { message: 'Escribí por qué se anula', code: 'P0001' } }
    const { result } = renderHook(() => useAnularGastoMutation(), { wrapper: makeWrapper(nuevoCliente()) })

    const error = await result.current.mutateAsync({ id: 7, motivo: '' }).catch((e: unknown) => e)

    expect((error as Error).message).toBe('Escribí por qué se anula')
  })
})

describe('useGastosDelMesQuery', () => {
  it('lee la ventana del mes sin anulados', async () => {
    const { result } = renderHook(() => useGastosDelMesQuery('2026-10-01'), { wrapper: makeWrapper(nuevoCliente()) })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(fromCalls).toEqual(['gastos'])
    const llamadas = chainCalls.map(c => [c.method, ...c.args])
    expect(llamadas).toContainEqual(['lte', 'mes_imputado', '2026-10-01'])
    expect(llamadas).toContainEqual(['gte', 'mes_fin', '2026-10-01'])
    expect(llamadas).toContainEqual(['is', 'anulado_at', null])
    expect(llamadas).toContainEqual(['order', 'fecha', { ascending: false }])
  })

  it('pide columnas explícitas y los dos embeds', async () => {
    const { result } = renderHook(() => useGastosDelMesQuery('2026-10-01'), { wrapper: makeWrapper(nuevoCliente()) })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    const select = chainCalls.find(c => c.method === 'select')?.args[0] as string
    expect(select).not.toContain('*')
    expect(select).toContain('rubro:gasto_rubros(id,nombre,grupo)')
    expect(select).toContain('vehiculo:vehiculos(id,patente,descripcion)')
    expect(select).toContain('mes_fin')
  })
})

describe('useKmDelGastoQuery', () => {
  it('lee la lectura de km del gasto y devuelve los km', async () => {
    datosPorTabla = { vehiculo_km: { km: 184230 } }
    const { result } = renderHook(() => useKmDelGastoQuery(41), { wrapper: makeWrapper(nuevoCliente()) })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(result.current.data).toBe(184230)
    expect(fromCalls).toEqual(['vehiculo_km'])
    const llamadas = chainCalls.map(c => [c.method, ...c.args])
    expect(llamadas).toContainEqual(['eq', 'gasto_id', 41])
    expect(llamadas.some(l => l[0] === 'maybeSingle')).toBe(true)
  })

  it('sin lectura devuelve null', async () => {
    datosPorTabla = { vehiculo_km: null }
    const { result } = renderHook(() => useKmDelGastoQuery(41), { wrapper: makeWrapper(nuevoCliente()) })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(result.current.data).toBeNull()
  })

  it('sin gasto (alta) no consulta', () => {
    renderHook(() => useKmDelGastoQuery(null), { wrapper: makeWrapper(nuevoCliente()) })
    expect(fromCalls).toEqual([])
  })
})

describe('useRendicionesCerradasQuery', () => {
  const CLAVES = [
    { transportista_id: 'tr-1', fecha: '2026-10-27' },
    { transportista_id: 'tr-2', fecha: '2026-10-28' },
  ]

  it('lee las cerradas de esas fechas y se queda con las claves pedidas', async () => {
    // tr-1 también cerró el 28, pero esa rendición no se pidió.
    datosPorTabla = {
      rendiciones_control: [
        { transportista_id: 'tr-1', fecha: '2026-10-27' },
        { transportista_id: 'tr-1', fecha: '2026-10-28' },
      ],
    }
    const { result } = renderHook(() => useRendicionesCerradasQuery(CLAVES), { wrapper: makeWrapper(nuevoCliente()) })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(fromCalls).toEqual(['rendiciones_control'])
    const llamadas = chainCalls.map(c => [c.method, ...c.args])
    expect(llamadas).toContainEqual(['select', 'transportista_id,fecha'])
    expect(llamadas).toContainEqual(['in', 'estado', ['confirmada', 'resuelta']])
    expect(llamadas).toContainEqual(['in', 'fecha', ['2026-10-27', '2026-10-28']])
    expect([...result.current.data!]).toEqual(['tr-1|2026-10-27'])
  })

  it('sin claves no consulta', () => {
    renderHook(() => useRendicionesCerradasQuery([]), { wrapper: makeWrapper(nuevoCliente()) })
    expect(fromCalls).toEqual([])
  })
})

describe('gastosKeys.todas', () => {
  it('es el prefijo de todas las sucursales', () => {
    expect(gastosKeys.todas()).toEqual(['gastos'])
    expect(gastosKeys.all(1).slice(0, 1)).toEqual(gastosKeys.todas())
  })
})

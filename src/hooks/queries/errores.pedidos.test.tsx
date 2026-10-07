/**
 * Issue #760 — lote pedidos / rutas / entregas / salvedades.
 *
 * EL BUG: supabase-js no lanza `Error`: devuelve un objeto plano
 * `{ message, details, hint, code }`. Los hooks hacían `if (error) throw error` y
 * la UI (`err instanceof Error ? err.message : '<literal>'`) descartaba el mensaje
 * real del servidor, y un corte de red se mostraba igual que un rechazo.
 *
 * Por eso los errores de acá son SIEMPRE la forma real (objeto plano), nunca
 * `new Error(...)`: mockearlos como Error hacía pasar en verde el bug.
 *
 * Por cada hook se verifica:
 *  1. el servidor respondió  → llega un `Error`, con el mensaje del servidor y el
 *     `code`/`details`/`hint` conservados;
 *  2. no hubo servidor       → llega el mensaje accionable de "sin conexión" (no
 *     'Failed to fetch') y `isTransientNetworkError` sigue siendo true.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, waitFor, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

type ErrorPlano = { message: string; details: string; hint: string; code: string }

const ERROR_SERVIDOR: ErrorPlano = {
  message: 'La ruta ya tiene 3 entregas hechas',
  details: 'detalle del servidor',
  hint: 'pista del servidor',
  code: 'P0001',
}
const ERROR_RED: ErrorPlano = {
  message: 'TypeError: Failed to fetch',
  details: '',
  hint: '',
  code: '',
}

let resultado: { data: unknown; error: ErrorPlano | null } = { data: null, error: null }
let llamadasRpc = 0

/** Builder encadenable y "thenable": cualquier método devuelve el mismo builder. */
function builder(): unknown {
  const b: unknown = new Proxy(
    {},
    {
      get(_t, prop) {
        if (prop === 'then') {
          return (res: (v: unknown) => unknown, rej: (e: unknown) => unknown) =>
            Promise.resolve(resultado).then(res, rej)
        }
        return () => b
      },
    },
  )
  return b
}

vi.mock('../supabase/base', () => ({
  supabase: {
    from: () => builder(),
    rpc: () => {
      llamadasRpc++
      return builder()
    },
    auth: { getUser: () => Promise.resolve({ data: { user: { id: 'u1' } } }) },
  },
  notifyError: vi.fn(),
}))

// useAnularSalvedadMutation importa (transitivo) el cliente real de lib/supabase.
vi.mock('../../lib/supabase', () => ({ supabase: {} }))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 2 }),
}))

import { isTransientNetworkError } from '../../utils/retryWithBackoff'
import {
  usePedidoQuery,
  usePedidosByTransportistaQuery,
  usePedidosByClienteQuery,
  usePedidosPaginatedQuery,
  useCrearPedidoMutation,
  useCambiarTipoFacturaMutation,
  useCambiarEstadoMutation,
  useActualizarPagoMutation,
  useAsignarTransportistaMutation,
  useQuitarPedidoDeRecorridosMutation,
  useEliminarPedidoMutation,
  useEntregasMasivasMutation,
  useCancelarPedidoMutation,
  useCambiarClientePedidoMutation,
  usePagosMasivosMutation,
  useEntregaYPagoMasivosMutation,
} from './usePedidosQuery'
import { usePedidosTrabadosQuery } from './usePedidosTrabadosQuery'
import { useNoEntregadosQuery, usePedidosSinResolverQuery } from './useNoEntregadosQuery'
import { useAnularSalvedadMutation } from './useAnularSalvedadMutation'
import { useSimularSalvedadesPromoImpactoQuery } from './useSimularSalvedadesQuery'
import { useSimularSalvedadPromoImpactoQuery } from './useSimularSalvedadQuery'
import { useSustituirRegaloMutation, useDividirRegaloMutation } from './useSustituirRegaloMutation'
import { useCambiarTransportistaRutaMutation } from './useCambiarTransportistaRutaMutation'
import { useRutasEnCursoQuery, useRutasEnCursoMultiQuery } from './useRutasEnCursoQuery'
import { useRecorridoActivoQuery } from './useRecorridoActivoQuery'
import { useRecorridoExistenteQuery } from './useRecorridoExistenteQuery'
import { useRecorridosHojaRutaQuery } from './useRecorridosHojaRutaQuery'
import {
  useDepositoCoords,
  useDestinoCoords,
  useSetDepositoMutation,
  useSetDestinoMutation,
  depositoKeys,
  destinoKeys,
} from './useDepositoQuery'
import { useRecorridos } from '../supabase/useRecorridos'
import { useSalvedades } from '../supabase/useSalvedades'
import { useCandidatosEscaneoQuery, useRegistrarEquivalenciasMutation } from './useEscaneoQuery'
import {
  useControlStockSesionesQuery,
  useControlStockDetalleQuery,
  useAplicarControlStockMutation,
} from './useControlStockQuery'

function crearQc() {
  return new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  })
}

function wrapperDe(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

async function errorDeQuery(useHook: () => { isError: boolean; error: unknown }): Promise<unknown> {
  const { result } = renderHook(useHook, { wrapper: wrapperDe(crearQc()) })
  await waitFor(() => expect(result.current.isError).toBe(true))
  return result.current.error
}

function verificarServidor(e: unknown) {
  expect(e).toBeInstanceOf(Error)
  const err = e as Error & { code?: string; details?: string; hint?: string }
  expect(err.message).toBe(ERROR_SERVIDOR.message)
  expect(err.code).toBe('P0001')
  expect(err.details).toBe(ERROR_SERVIDOR.details)
  expect(err.hint).toBe(ERROR_SERVIDOR.hint)
  expect(isTransientNetworkError(e)).toBe(false)
}

function verificarRed(e: unknown) {
  expect(e).toBeInstanceOf(Error)
  const msg = (e as Error).message
  expect(msg).toMatch(/^Sin conexión: /)
  expect(msg).not.toMatch(/failed to fetch/i)
  expect(isTransientNetworkError(e)).toBe(true)
}

// ---------------------------------------------------------------------------
// LECTURAS
// ---------------------------------------------------------------------------

const lecturas: Array<[string, () => { isError: boolean; error: unknown }]> = [
  ['usePedidoQuery', () => usePedidoQuery('1')],
  ['usePedidosByTransportistaQuery', () => usePedidosByTransportistaQuery('t1')],
  ['usePedidosByClienteQuery', () => usePedidosByClienteQuery('1')],
  ['usePedidosPaginatedQuery', () => usePedidosPaginatedQuery(1, 10, {}, '')],
  ['usePedidosTrabadosQuery', () => usePedidosTrabadosQuery(true)],
  ['useNoEntregadosQuery', () => useNoEntregadosQuery('2026-01-01', '2026-01-31')],
  ['usePedidosSinResolverQuery', () => usePedidosSinResolverQuery(true)],
  [
    'useSimularSalvedadesPromoImpactoQuery',
    () => useSimularSalvedadesPromoImpactoQuery('1', [{ pedidoItemId: '1', cantidadAfectada: 1 }]),
  ],
  ['useSimularSalvedadPromoImpactoQuery', () => useSimularSalvedadPromoImpactoQuery('1', '2', 1)],
  ['useRutasEnCursoQuery', () => useRutasEnCursoQuery('t1')],
  ['useRutasEnCursoMultiQuery', () => useRutasEnCursoMultiQuery(['t1', 't2'])],
  ['useRecorridoActivoQuery', () => useRecorridoActivoQuery('t1')],
  ['useRecorridoExistenteQuery', () => useRecorridoExistenteQuery('t1', '2026-01-01')],
  ['useRecorridosHojaRutaQuery', () => useRecorridosHojaRutaQuery('2026-01-01')],
  ['useCandidatosEscaneoQuery', () => useCandidatosEscaneoQuery('5')],
  ['useControlStockSesionesQuery', () => useControlStockSesionesQuery(true)],
  ['useControlStockDetalleQuery', () => useControlStockDetalleQuery(7)],
]

describe('lecturas del dominio pedidos: el error de supabase llega como Error', () => {
  beforeEach(() => {
    resultado = { data: null, error: null }
  })

  describe.each(lecturas)('%s', (_nombre, useHook) => {
    it('error del servidor: Error con el mensaje y el code del servidor', async () => {
      resultado = { data: null, error: ERROR_SERVIDOR }
      verificarServidor(await errorDeQuery(useHook))
    })

    it('sin red: mensaje de sin conexión y sigue siendo transitorio', async () => {
      resultado = { data: null, error: ERROR_RED }
      verificarRed(await errorDeQuery(useHook))
    })
  })

  // `useDepositoCoords` / `useDestinoCoords` devuelven coordenadas, no la
  // query: el error se lee del estado en el cache.
  describe.each([
    ['useDepositoCoords', () => useDepositoCoords(), depositoKeys.all(2)],
    ['useDestinoCoords', () => useDestinoCoords(), destinoKeys.all(2)],
  ] as const)('%s', (_n, useHook, key) => {
    async function errorEnCache() {
      const qc = crearQc()
      renderHook(useHook, { wrapper: wrapperDe(qc) })
      await waitFor(() => expect(qc.getQueryState(key)?.status).toBe('error'))
      return qc.getQueryState(key)?.error
    }
    it('error del servidor', async () => {
      resultado = { data: null, error: ERROR_SERVIDOR }
      verificarServidor(await errorEnCache())
    })
    it('sin red', async () => {
      resultado = { data: null, error: ERROR_RED }
      verificarRed(await errorEnCache())
    })
  })
})

// ---------------------------------------------------------------------------
// ESCRITURAS
// ---------------------------------------------------------------------------

type Mutacion = { mutateAsync: (v: never) => Promise<unknown> }

const escrituras: Array<[string, () => Mutacion, unknown]> = [
  ['useCrearPedidoMutation', () => useCrearPedidoMutation() as unknown as Mutacion, { items: [], total: 0 }],
  ['useCambiarTipoFacturaMutation', () => useCambiarTipoFacturaMutation() as unknown as Mutacion, { pedidoId: '1', tipo: 'FC' }],
  ['useCambiarEstadoMutation', () => useCambiarEstadoMutation() as unknown as Mutacion, { pedidoId: '1', estado: 'pendiente' }],
  ['useActualizarPagoMutation', () => useActualizarPagoMutation() as unknown as Mutacion, { pedidoId: '1', montoPagado: 10 }],
  ['useAsignarTransportistaMutation', () => useAsignarTransportistaMutation() as unknown as Mutacion, { pedidoId: '1', transportistaId: 't1' }],
  ['useQuitarPedidoDeRecorridosMutation', () => useQuitarPedidoDeRecorridosMutation() as unknown as Mutacion, { pedidoId: '1' }],
  ['useEliminarPedidoMutation', () => useEliminarPedidoMutation() as unknown as Mutacion, { id: '1' }],
  ['useEntregasMasivasMutation', () => useEntregasMasivasMutation() as unknown as Mutacion, { pedidoIds: ['1'], transportistaId: 't1' }],
  ['useCancelarPedidoMutation', () => useCancelarPedidoMutation() as unknown as Mutacion, { pedidoId: '1', motivo: 'x' }],
  ['useCambiarClientePedidoMutation', () => useCambiarClientePedidoMutation() as unknown as Mutacion, { pedidoId: '1', nuevoClienteId: '2', usuarioId: 'u', items: [], total: 0 }],
  ['usePagosMasivosMutation', () => usePagosMasivosMutation() as unknown as Mutacion, { pedidoIds: ['1'], formaPago: 'efectivo' }],
  ['useAnularSalvedadMutation', () => useAnularSalvedadMutation() as unknown as Mutacion, { salvedadId: '1', notas: 'x' }],
  ['useSustituirRegaloMutation', () => useSustituirRegaloMutation() as unknown as Mutacion, { pedidoItemId: 1, productoNuevoId: 2, cantidadNueva: 1, motivo: 'x', clientRequestId: 'req-1' }],
  ['useDividirRegaloMutation', () => useDividirRegaloMutation() as unknown as Mutacion, { pedidoItemId: 1, partes: [{ productoId: 2, cantidad: 1 }], motivo: 'x', clientRequestId: 'req-1' }],
  ['useCambiarTransportistaRutaMutation', () => useCambiarTransportistaRutaMutation() as unknown as Mutacion, { recorridoId: '1', transportistaId: 't1' }],
  ['useSetDepositoMutation', () => useSetDepositoMutation() as unknown as Mutacion, { lat: -26, lng: -65 }],
  ['useSetDestinoMutation', () => useSetDestinoMutation() as unknown as Mutacion, { lat: -26, lng: -65 }],
  ['useRegistrarEquivalenciasMutation', () => useRegistrarEquivalenciasMutation() as unknown as Mutacion, { proveedorId: '1', items: [{}] }],
  ['useAplicarControlStockMutation', () => useAplicarControlStockMutation() as unknown as Mutacion, []],
]

/**
 * Fake timers: `useCrearPedidoMutation` y `usePagosMasivosMutation` reintentan
 * los blips de red con 1 s / 2 s de espera.
 */
async function errorDeMutacion(useHook: () => Mutacion, vars: unknown): Promise<unknown> {
  const { result } = renderHook(useHook, { wrapper: wrapperDe(crearQc()) })
  let p!: Promise<unknown>
  act(() => {
    p = result.current.mutateAsync(vars as never).then(
      () => null,
      (e: unknown) => e,
    )
  })
  await act(async () => {
    await vi.advanceTimersByTimeAsync(10_000)
  })
  return p
}

describe('escrituras del dominio pedidos: el error de supabase llega como Error', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    resultado = { data: null, error: null }
    llamadasRpc = 0
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  describe.each(escrituras)('%s', (_nombre, useHook, vars) => {
    it('error del servidor: Error con el mensaje y el code del servidor', async () => {
      resultado = { data: null, error: ERROR_SERVIDOR }
      verificarServidor(await errorDeMutacion(useHook, vars))
    })

    it('sin red: mensaje de sin conexión y sigue siendo transitorio', async () => {
      resultado = { data: null, error: ERROR_RED }
      verificarRed(await errorDeMutacion(useHook, vars))
    })
  })

  it('useEntregaYPagoMasivosMutation: el mensaje del paso fallido es el del servidor / el de sin conexión', async () => {
    const vars = { idsEntregar: ['1'], idsCobrar: [], transportistaId: 't1', formaPago: 'efectivo' }

    resultado = { data: null, error: ERROR_SERVIDOR }
    const { result } = renderHook(() => useEntregaYPagoMasivosMutation(), { wrapper: wrapperDe(crearQc()) })
    let datos!: { error?: { paso: string; mensaje: string } }
    await act(async () => {
      datos = await result.current.mutateAsync(vars as never)
    })
    expect(datos.error).toEqual({ paso: 'entregar', mensaje: ERROR_SERVIDOR.message })

    resultado = { data: null, error: ERROR_RED }
    await act(async () => {
      datos = await result.current.mutateAsync(vars as never)
    })
    expect(datos.error?.paso).toBe('entregar')
    expect(datos.error?.mensaje).toMatch(/^Sin conexión: /)
    expect(datos.error?.mensaje).not.toMatch(/failed to fetch/i)
  })
})

// ---------------------------------------------------------------------------
// REINTENTO (usePedidosQuery.ts: `retry: ... isTransientNetworkError(error)`)
// ---------------------------------------------------------------------------

describe('reintento de las mutaciones idempotentes', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    resultado = { data: null, error: null }
    llamadasRpc = 0
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  // Acá el QueryClient NO apaga el retry de la mutación: lo decide el hook.
  async function correr(useHook: () => Mutacion, vars: unknown) {
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const { result } = renderHook(useHook, { wrapper: wrapperDe(qc) })
    let p!: Promise<unknown>
    act(() => {
      p = result.current.mutateAsync(vars as never).then(
        () => null,
        (e: unknown) => e,
      )
    })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(10_000)
    })
    return p
  }

  describe.each([
    ['useCrearPedidoMutation', () => useCrearPedidoMutation() as unknown as Mutacion, { items: [], total: 0 }],
    ['usePagosMasivosMutation', () => usePagosMasivosMutation() as unknown as Mutacion, { pedidoIds: ['1'], formaPago: 'efectivo' }],
  ])('%s', (_n, useHook, vars) => {
    it('un corte de red se reintenta (1 intento + 2 reintentos)', async () => {
      resultado = { data: null, error: ERROR_RED }
      const e = await correr(useHook, vars)
      expect(llamadasRpc).toBe(3)
      verificarRed(e)
    })

    it('un rechazo del servidor NO se reintenta', async () => {
      resultado = { data: null, error: ERROR_SERVIDOR }
      const e = await correr(useHook, vars)
      expect(llamadasRpc).toBe(1)
      verificarServidor(e)
    })
  })
})

// ---------------------------------------------------------------------------
// HOOKS VIEJOS (src/hooks/supabase): siguen en uso en RecorridosContainer y
// VistaSalvedades. No usan react-query: se llaman directo.
// ---------------------------------------------------------------------------

describe('hooks de src/hooks/supabase: crear/completar recorrido y resolver salvedad', () => {
  beforeEach(() => {
    resultado = { data: null, error: null }
  })

  const casos: Array<[string, () => Promise<unknown>]> = [
    [
      'useRecorridos.crearRecorrido',
      async () => {
        const { result } = renderHook(() => useRecorridos())
        return result.current.crearRecorrido('t1', [{ pedido_id: '1' } as never])
      },
    ],
    [
      'useRecorridos.completarRecorrido',
      async () => {
        const { result } = renderHook(() => useRecorridos())
        return result.current.completarRecorrido('1')
      },
    ],
    [
      'useSalvedades.resolverSalvedad',
      async () => {
        const { result } = renderHook(() => useSalvedades())
        return result.current.resolverSalvedad({ salvedadId: '1', estadoResolucion: 'resuelta' } as never)
      },
    ],
  ]

  describe.each(casos)('%s', (_n, correr) => {
    it('error del servidor', async () => {
      resultado = { data: null, error: ERROR_SERVIDOR }
      verificarServidor(await correr().then(() => null, (e: unknown) => e))
    })
    it('sin red', async () => {
      resultado = { data: null, error: ERROR_RED }
      verificarRed(await correr().then(() => null, (e: unknown) => e))
    })
  })
})

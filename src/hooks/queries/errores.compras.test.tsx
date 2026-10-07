/**
 * Los errores de los hooks de compras / proveedores / lotes / stock /
 * movimientos / rendiciones tienen que llegar a la pantalla como `Error` con el
 * mensaje real (issue #760).
 *
 * supabase-js NO lanza `Error`: devuelve un objeto plano
 * `{ message, details, hint, code }`. Un `throw error` pelado hacía que el
 * `err instanceof Error ? err.message : '<literal>'` de la UI diera siempre
 * false y se perdiera el texto del servidor. Acá se usa SIEMPRE la forma real
 * del error —nunca `new Error(...)`—, que fue lo que dejó pasar en verde el bug.
 *
 * Dos formas, y las dos se prueban en cada hook:
 *   - respondió el servidor → `code: 'P0001'`: el mensaje y el código llegan igual.
 *   - no hubo red           → `code: ''`: mensaje de "sin conexión" y
 *                             `isTransientNetworkError` sigue true (el reintento).
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

type ErrorPlano = { message: string; details: string; hint: string; code: string }

const ERROR_SERVIDOR: ErrorPlano = {
  message: 'Acceso denegado: se requiere rol admin',
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

const estado = vi.hoisted(() => ({
  respuesta: { data: null, error: null } as { data: unknown; error: unknown },
}))

/** Cadena de PostgREST: cualquier método devuelve la cadena y `await` da la respuesta. */
function cadena(): unknown {
  const proxy: unknown = new Proxy(() => undefined, {
    get(_t, prop) {
      if (prop === 'then') {
        return (res: (v: unknown) => unknown, rej?: (e: unknown) => unknown) =>
          Promise.resolve({ ...estado.respuesta, count: null }).then(res, rej)
      }
      return () => proxy
    },
    apply: () => proxy,
  })
  return proxy
}

vi.mock('../supabase/base', () => {
  const supabase = {
    from: () => cadena(),
    rpc: () => Promise.resolve({ ...estado.respuesta }),
    auth: { getUser: () => Promise.resolve({ data: { user: { id: 'u1' } } }) },
  }
  return { supabase, notifyError: vi.fn() }
})
vi.mock('../../lib/supabase', async () => {
  const base = await import('../supabase/base')
  return { supabase: base.supabase }
})
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { isTransientNetworkError } from '../../utils/retryWithBackoff'
import {
  useComprasQuery, useCompraQuery, useComprasByProveedorQuery, useCargosPlantillaProveedorQuery,
  useComprasMismaFacturaQuery, useCostosAnterioresQuery, useComprasTransferenciasQuery,
  useRegistrarCompraMutation, useActualizarCompraMutation, useAnularCompraMutation,
  useCambiarProveedorCompraMutation,
} from './useComprasQuery'
import {
  useProveedoresQuery, useProveedoresActivosQuery, useProveedorQuery, useCrearProveedorMutation,
  useActualizarProveedorMutation, useToggleProveedorActivoMutation, useEliminarProveedorMutation,
} from './useProveedoresQuery'
import {
  useLotesProductoQuery, useLotesCompraQuery, useVencimientosQuery, useSincronizarLotesCompraMutation,
  useCrearLoteManualMutation, useAjustarLoteMutation, useDarDeBajaLoteMutation,
  useRegistrarNotaCreditoLoteMutation,
} from './useLotesQuery'
import { useSucursalesQuery } from './useTransferenciasQuery'
import { useStockRedQuery } from './useStockRedQuery'
import { useValuacionInventarioQuery } from './useValuacionInventarioQuery'
import {
  useNotasCreditoByCompraQuery, useNotasCreditoResumenQuery, useRegistrarNotaCreditoMutation,
} from './useNotasCreditoQuery'
import {
  useNotasCreditoVentaClienteQuery, useNotasCreditoVentaPedidoQuery,
  useCrearNotaCreditoVentaMutation, useAnularNotaCreditoVentaMutation,
} from './useNotasCreditoVentaQuery'
import {
  useMovimientosQuery, useMovimientoItemsQuery, useCrearMovimientoMutation,
  useAceptarMovimientoMutation, useDenegarMovimientoMutation, useCancelarMovimientoMutation,
  useEditarMovimientoMutation,
} from './useMovimientosQuery'
import { useUltimaFechaCajaCerradaQuery } from './useUltimaFechaCajaCerradaQuery'
import { useRendicionCerradaQuery } from './useRendicionCerradaQuery'
import {
  useRegistrarCambioProductoMutation, useCrearPedidoCambioEnRutaMutation, useAplicarCambioParadaMutation,
} from './useCambiosProductosQuery'
import { useRendiciones } from '../supabase/useRendiciones'

function wrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}
const nuevoQc = () => new QueryClient({
  defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
})

const compraInput = {
  proveedorId: '3', proveedorNombre: null, numeroFactura: 'A0005-1', fechaCompra: '2026-08-19',
  subtotal: 100, iva: 21, impuestosInternos: 0, otrosImpuestos: 0, total: 121, formaPago: 'efectivo',
  notas: null, tipoFactura: 'FC' as const, usuarioId: 'u1',
  items: [{ productoId: '7', cantidad: 1, costoUnitario: 100, subtotal: 100 }],
  cargos: [], iiDeclarado: {},
}
const edicionInput = {
  compraId: '221', usuarioId: 'u1', subtotal: 100, iva: 21, total: 121,
  items: [{ productoId: '7', cantidad: 1, costoUnitario: 100, subtotal: 100 }],
  cargos: [], iiDeclarado: {},
}
const proveedorForm = { nombre: 'Prov' }

interface Caso { nombre: string; correr: () => Promise<unknown> }

/** Una query: se monta y se espera a que quede en error. */
function query(nombre: string, hook: () => { error: unknown; isError: boolean }): Caso {
  return {
    nombre,
    correr: async () => {
      const { result } = renderHook(hook, { wrapper: wrapper(nuevoQc()) })
      await waitFor(() => expect(result.current.isError).toBe(true))
      return result.current.error
    },
  }
}

/** Una mutation: se dispara y se recoge lo que rechaza. */
function mutation(
  nombre: string,
  hook: () => { mutateAsync: (v: never) => Promise<unknown> },
  variables: unknown,
): Caso {
  return {
    nombre,
    correr: async () => {
      const { result } = renderHook(hook, { wrapper: wrapper(nuevoQc()) })
      let err: unknown
      await act(async () => {
        err = await result.current.mutateAsync(variables as never).catch((e: unknown) => e)
      })
      return err
    },
  }
}

const FNS_RENDICION = [
  'marcarControlada', 'desmarcarControlada', 'confirmarRendicion', 'resolverRendicion', 'consultarControl',
] as const

const casos: Caso[] = [
  // compras
  query('useComprasQuery', () => useComprasQuery()),
  query('useCompraQuery', () => useCompraQuery('1')),
  query('useComprasByProveedorQuery', () => useComprasByProveedorQuery('3')),
  query('useCargosPlantillaProveedorQuery', () => useCargosPlantillaProveedorQuery('3')),
  query('useComprasMismaFacturaQuery', () =>
    useComprasMismaFacturaQuery({ numeroFactura: 'A0005-00467758', proveedorId: '3' } as never)),
  query('useCostosAnterioresQuery', () =>
    useCostosAnterioresQuery(['7'], { fechaCompra: '2026-08-19', compraId: null } as never)),
  query('useComprasTransferenciasQuery', () => useComprasTransferenciasQuery()),
  mutation('useRegistrarCompraMutation', () => useRegistrarCompraMutation(), compraInput),
  mutation('useActualizarCompraMutation', () => useActualizarCompraMutation(), edicionInput),
  mutation('useAnularCompraMutation', () => useAnularCompraMutation(), '221'),
  mutation('useCambiarProveedorCompraMutation', () => useCambiarProveedorCompraMutation(), {
    compraId: '221', nuevoProveedorId: '3', nuevoProveedorNombre: null, usuarioId: 'u1',
  }),
  // proveedores
  query('useProveedoresQuery', () => useProveedoresQuery()),
  query('useProveedoresActivosQuery', () => useProveedoresActivosQuery()),
  query('useProveedorQuery', () => useProveedorQuery('3')),
  mutation('useCrearProveedorMutation', () => useCrearProveedorMutation(), proveedorForm),
  mutation('useActualizarProveedorMutation', () => useActualizarProveedorMutation(), { id: '3', data: proveedorForm }),
  mutation('useToggleProveedorActivoMutation', () => useToggleProveedorActivoMutation(), { id: '3', activo: false }),
  mutation('useEliminarProveedorMutation', () => useEliminarProveedorMutation(), '3'),
  // lotes
  query('useLotesProductoQuery', () => useLotesProductoQuery(7)),
  query('useLotesCompraQuery', () => useLotesCompraQuery(221)),
  query('useVencimientosQuery', () => useVencimientosQuery()),
  mutation('useSincronizarLotesCompraMutation', () => useSincronizarLotesCompraMutation(), { compraId: 1, lotes: [] }),
  mutation('useCrearLoteManualMutation', () => useCrearLoteManualMutation(), { productoId: 7, fecha: '2026-12-01', cantidad: 3 }),
  mutation('useAjustarLoteMutation', () => useAjustarLoteMutation(), { loteId: 1, cantidadRestante: 2 }),
  mutation('useDarDeBajaLoteMutation', () => useDarDeBajaLoteMutation(), { loteId: 1, cantidad: 2 }),
  mutation('useRegistrarNotaCreditoLoteMutation', () => useRegistrarNotaCreditoLoteMutation(), {
    loteId: 1, cantidad: 2, numeroNota: 'NC-1',
  }),
  // sucursales / stock / valuación
  query('useSucursalesQuery', () => useSucursalesQuery()),
  query('useStockRedQuery', () => useStockRedQuery(null)),
  query('useValuacionInventarioQuery', () => useValuacionInventarioQuery(null)),
  // notas de crédito (compra y venta)
  query('useNotasCreditoByCompraQuery', () => useNotasCreditoByCompraQuery('221')),
  query('useNotasCreditoResumenQuery', () => useNotasCreditoResumenQuery()),
  mutation('useRegistrarNotaCreditoMutation', () => useRegistrarNotaCreditoMutation(), {
    compraId: '221', subtotal: 100, iva: 21, total: 121, items: [],
  }),
  query('useNotasCreditoVentaClienteQuery', () => useNotasCreditoVentaClienteQuery('5')),
  query('useNotasCreditoVentaPedidoQuery', () => useNotasCreditoVentaPedidoQuery('9')),
  mutation('useCrearNotaCreditoVentaMutation', () => useCrearNotaCreditoVentaMutation(), {
    pedidoId: '9', clienteId: '5', items: [], motivo: 'devolucion', clientRequestId: 'r1',
  }),
  mutation('useAnularNotaCreditoVentaMutation', () => useAnularNotaCreditoVentaMutation(), { notaCreditoId: '4' }),
  // movimientos entre sucursales
  query('useMovimientosQuery', () => useMovimientosQuery()),
  query('useMovimientoItemsQuery', () => useMovimientoItemsQuery('8')),
  mutation('useCrearMovimientoMutation', () => useCrearMovimientoMutation(), { sucursalDestinoId: 2, items: [] }),
  mutation('useAceptarMovimientoMutation', () => useAceptarMovimientoMutation(), { movimientoId: 8, resoluciones: [] }),
  mutation('useDenegarMovimientoMutation', () => useDenegarMovimientoMutation(), { movimientoId: 8 }),
  mutation('useCancelarMovimientoMutation', () => useCancelarMovimientoMutation(), { movimientoId: 8 }),
  mutation('useEditarMovimientoMutation', () => useEditarMovimientoMutation(), { movimientoId: 8, items: [] }),
  // caja / rendición
  query('useUltimaFechaCajaCerradaQuery', () => useUltimaFechaCajaCerradaQuery()),
  query('useRendicionCerradaQuery', () => useRendicionCerradaQuery('2026-10-01')),
  // cambios de productos
  mutation('useRegistrarCambioProductoMutation', () => useRegistrarCambioProductoMutation(), {
    clienteId: '5', productoDevueltoId: '1', cantidadDevuelta: 1, productoEntregadoId: '2', cantidadEntregada: 1,
  }),
  mutation('useCrearPedidoCambioEnRutaMutation', () => useCrearPedidoCambioEnRutaMutation(), {
    clienteId: '5', productoDevueltoId: '1', cantidadDevuelta: 1, productoEntregadoId: '2', cantidadEntregada: 1,
  }),
  mutation('useAplicarCambioParadaMutation', () => useAplicarCambioParadaMutation(), '9'),
  // rendiciones (hook con estado, no TanStack): se llama la función y se recoge el rechazo
  ...FNS_RENDICION.map((fn): Caso => ({
    nombre: `useRendiciones.${fn}`,
    correr: async () => {
      const { result } = renderHook(() => useRendiciones())
      const f = result.current[fn] as (...a: unknown[]) => Promise<unknown>
      const args: Record<typeof FNS_RENDICION[number], unknown[]> = {
        marcarControlada: ['2026-10-01', 't1'],
        desmarcarControlada: ['2026-10-01', 't1'],
        confirmarRendicion: ['2026-10-01', 't1', 'confirmada'],
        resolverRendicion: ['2026-10-01', 't1', 'obs'],
        consultarControl: ['t1', '2026-10-01'],
      }
      let err: unknown
      await act(async () => {
        err = await f(...args[fn]).catch((e: unknown) => e)
      })
      return err
    },
  })),
]

describe('errores de supabase en los hooks de compras y afines (#760)', () => {
  beforeEach(() => {
    estado.respuesta = { data: null, error: null }
  })

  describe.each(casos)('$nombre', ({ correr }) => {
    it('con error del servidor: es un Error con el mensaje y el code del servidor', async () => {
      estado.respuesta = { data: null, error: ERROR_SERVIDOR }
      const err = await correr()

      expect(err).toBeInstanceOf(Error)
      expect((err as Error).message).toBe(ERROR_SERVIDOR.message)
      expect((err as { code?: string }).code).toBe('P0001')
      expect(isTransientNetworkError(err)).toBe(false)
    })

    it('sin red: mensaje de sin conexión (no "Failed to fetch") y sigue siendo transitorio', async () => {
      estado.respuesta = { data: null, error: ERROR_RED }
      const err = await correr()

      expect(err).toBeInstanceOf(Error)
      expect((err as Error).message).toMatch(/sin conexión/i)
      expect((err as Error).message).not.toMatch(/failed to fetch/i)
      expect(isTransientNetworkError(err)).toBe(true)
    })
  })

  it('useMovimientosQuery: un PGRST103 que se repite en la página 1 sale como Error con su mensaje', async () => {
    estado.respuesta = {
      data: null,
      error: { message: 'Requested range not satisfiable', details: '', hint: '', code: 'PGRST103' },
    }
    const { result } = renderHook(() => useMovimientosQuery({ pagina: 3 }), { wrapper: wrapper(nuevoQc()) })
    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(result.current.error).toBeInstanceOf(Error)
    expect((result.current.error as Error).message).toBe('Requested range not satisfiable')
  })
})

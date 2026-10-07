/**
 * Issue #760, lote "catalogo": los hooks de productos y catálogo tiraban el
 * `error` crudo de supabase-js, que es un OBJETO PLANO y no un `Error`. La UI
 * (`err instanceof Error ? err.message : '<literal>'`) lo descartaba siempre y
 * mostraba su texto genérico, tanto para "se requiere rol admin" como para un
 * blip de 4G.
 *
 * Los errores acá tienen la forma REAL de supabase-js, nunca `new Error(...)`:
 *   - respondió el servidor → { message, details, hint, code: 'P0001' }
 *   - no hubo red           → { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' }
 *
 * Por cada hook se verifica: (1) con error de servidor llega un `Error` con el
 * mismo `message` y el `code` conservado; (2) sin red el mensaje es el de "sin
 * conexión" (no 'Failed to fetch') y `isTransientNetworkError` sigue true.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { isTransientNetworkError } from '../../utils/retryWithBackoff'

type ErrorPlano = { message: string; details: string; hint: string; code: string }

const ERROR_SERVIDOR: ErrorPlano = {
  message: 'se requiere rol admin',
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

const { estado, supabaseMock } = vi.hoisted(() => {
  const estado = { error: null as ErrorPlano | null }
  /**
   * Un builder que acepta cualquier cadena (`from().select().eq()...`) y al
   * `await`earse resuelve con el error de turno; `rpc()` ídem.
   */
  const cadena = (): unknown => {
    const proxy: unknown = new Proxy(() => undefined, {
      get(_t, prop) {
        if (prop === 'then') {
          return (ok: (v: unknown) => unknown, ko?: (e: unknown) => unknown) =>
            Promise.resolve({ data: null, error: estado.error, count: null }).then(ok, ko)
        }
        return () => proxy
      },
    })
    return proxy
  }
  return { estado, supabaseMock: { from: () => cadena(), rpc: () => cadena() } }
})

vi.mock('../supabase/base', () => ({ supabase: supabaseMock, notifyError: vi.fn() }))
vi.mock('../../lib/supabase', () => ({ supabase: supabaseMock }))
vi.mock('../../lib/offlineDb', () => ({
  cacheData: vi.fn().mockResolvedValue(undefined),
  getCachedData: vi.fn().mockResolvedValue(null),
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 2 }),
}))

import { useProductosQuery, useProductoQuery, useMinimosVentaQuery, useCrearProductoMutation, useActualizarProductoMutation, useEliminarProductoMutation, useDescontarStockMutation, useActualizarPreciosMasivoMutation, useActualizarMinimoVentaMasivoMutation } from './useProductosQuery'
import { useCategoriasQuery, useCrearCategoriaMutation, useRenombrarCategoriaMutation, useEliminarCategoriaMutation, useToggleCategoriaActivaMutation, useCrearSubcategoriaMutation, useRenombrarSubcategoriaMutation, useEliminarSubcategoriaMutation } from './useCategoriasQuery'
import { useMarcasQuery, useCrearMarcaMutation, useRenombrarMarcaMutation, useEliminarMarcaMutation, useToggleMarcaActivaMutation, useAsignarMarcaMasivaMutation } from './useMarcasQuery'
import { useGruposPrecioQuery, useCrearGrupoPrecioMutation, useActualizarGrupoPrecioMutation, useEliminarGrupoPrecioMutation, useToggleGrupoPrecioActivoMutation, useActualizarPrecioEscalaMutation, useAgregarProductoACondicionMutation, useQuitarProductoDeCondicionMutation, useCrearEscalaMutation, useActualizarEscalaMutation, useEliminarEscalaMutation, useCrearCondicionParaProductoMutation, useConsolidarCondicionesMutation } from './useGruposPrecioQuery'
import { usePromocionesListQuery, useCrearPromocionMutation, useActualizarPromocionMutation, useEliminarPromocionMutation, useTogglePromocionActivaMutation, useAjustarStockPromoMutation, contarReferenciasDePromocion, usePedidoSustitucionesQuery, usePreviewCambioFactorQuery } from './usePromocionesQuery'
import { useCatalogoIIQuery, useGuardarEncuadreIIMutation, useCambiarAlicuotaIIMutation, useCancelarAlicuotaProgramadaMutation } from './useImpuestosInternosQuery'
import { useCargoConceptosQuery, useCargoMedidasQuery, useProductoMedidasQuery, useGuardarProductoMedidasMutation } from './useCargosCatalogoQuery'
import { usePoliticasComercialesQuery, useActualizarMontoMinimoMutation, useActualizarComisionesDefaultMutation, useActualizarAlertasVencimientoMutation, useActualizarMostrarSinStockMutation, useImpactoMinimoQuery } from './usePoliticasComercialesQuery'
import { useMermasReporteQuery } from './useMermasReporteQuery'
import { useProductos } from '../supabase/useProductos'

function wrapper() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return function W({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

type Caso =
  | { nombre: string; tipo: 'query'; useCaso: () => unknown }
  | { nombre: string; tipo: 'mutation'; useCaso: () => unknown; args?: unknown }

const grupoInput = { nombre: 'g', descripcion: '', productoIds: ['1'], escalas: [{ cantidadMinima: 2, precioUnitario: 5 }] }
const promoInput = { nombre: 'p', tipo: 'bonificacion', fechaInicio: '2026-01-01', fechaFin: null, productoIds: ['1'], reglas: [{ clave: 'k', valor: '1' }] }

const casos: Caso[] = [
  // useProductosQuery
  { nombre: 'useProductosQuery', tipo: 'query', useCaso: () => useProductosQuery() },
  { nombre: 'useProductoQuery', tipo: 'query', useCaso: () => useProductoQuery('7') },
  { nombre: 'useMinimosVentaQuery', tipo: 'query', useCaso: () => useMinimosVentaQuery() },
  { nombre: 'useCrearProductoMutation', tipo: 'mutation', useCaso: () => useCrearProductoMutation(), args: { nombre: 'x', precio: 1 } },
  { nombre: 'useActualizarProductoMutation', tipo: 'mutation', useCaso: () => useActualizarProductoMutation(), args: { id: '1', data: { nombre: 'y' } } },
  { nombre: 'useEliminarProductoMutation', tipo: 'mutation', useCaso: () => useEliminarProductoMutation(), args: '1' },
  { nombre: 'useDescontarStockMutation', tipo: 'mutation', useCaso: () => useDescontarStockMutation(), args: [{ producto_id: '1', cantidad: 1 }] },
  { nombre: 'useActualizarPreciosMasivoMutation', tipo: 'mutation', useCaso: () => useActualizarPreciosMasivoMutation(), args: [] },
  { nombre: 'useActualizarMinimoVentaMasivoMutation', tipo: 'mutation', useCaso: () => useActualizarMinimoVentaMasivoMutation(), args: { categoriaId: '1', cantidad: 2 } },
  // useCategoriasQuery
  { nombre: 'useCategoriasQuery', tipo: 'query', useCaso: () => useCategoriasQuery() },
  { nombre: 'useCrearCategoriaMutation', tipo: 'mutation', useCaso: () => useCrearCategoriaMutation(), args: 'Lacteos' },
  { nombre: 'useRenombrarCategoriaMutation', tipo: 'mutation', useCaso: () => useRenombrarCategoriaMutation(), args: { id: '5', nombreViejo: 'a', nombreNuevo: 'b' } },
  { nombre: 'useEliminarCategoriaMutation', tipo: 'mutation', useCaso: () => useEliminarCategoriaMutation(), args: { id: '5', nombre: 'a' } },
  { nombre: 'useToggleCategoriaActivaMutation', tipo: 'mutation', useCaso: () => useToggleCategoriaActivaMutation(), args: { id: '5', activa: false, nombre: 'a' } },
  { nombre: 'useCrearSubcategoriaMutation', tipo: 'mutation', useCaso: () => useCrearSubcategoriaMutation(), args: { nombre: 's', parentId: '5' } },
  { nombre: 'useRenombrarSubcategoriaMutation', tipo: 'mutation', useCaso: () => useRenombrarSubcategoriaMutation(), args: { id: '5', nombre: 's2' } },
  { nombre: 'useEliminarSubcategoriaMutation', tipo: 'mutation', useCaso: () => useEliminarSubcategoriaMutation(), args: '5' },
  // useMarcasQuery
  { nombre: 'useMarcasQuery', tipo: 'query', useCaso: () => useMarcasQuery() },
  { nombre: 'useCrearMarcaMutation', tipo: 'mutation', useCaso: () => useCrearMarcaMutation(), args: 'Marca' },
  { nombre: 'useRenombrarMarcaMutation', tipo: 'mutation', useCaso: () => useRenombrarMarcaMutation(), args: { id: '1', nombreNuevo: 'M2' } },
  { nombre: 'useEliminarMarcaMutation', tipo: 'mutation', useCaso: () => useEliminarMarcaMutation(), args: '1' },
  { nombre: 'useToggleMarcaActivaMutation', tipo: 'mutation', useCaso: () => useToggleMarcaActivaMutation(), args: { id: '1', activa: false } },
  { nombre: 'useAsignarMarcaMasivaMutation', tipo: 'mutation', useCaso: () => useAsignarMarcaMasivaMutation(), args: { marcaId: '1', productoIds: ['2'] } },
  // useGruposPrecioQuery
  { nombre: 'useGruposPrecioQuery', tipo: 'query', useCaso: () => useGruposPrecioQuery() },
  { nombre: 'useCrearGrupoPrecioMutation', tipo: 'mutation', useCaso: () => useCrearGrupoPrecioMutation(), args: grupoInput },
  { nombre: 'useActualizarGrupoPrecioMutation', tipo: 'mutation', useCaso: () => useActualizarGrupoPrecioMutation(), args: { id: '1', data: grupoInput } },
  { nombre: 'useEliminarGrupoPrecioMutation', tipo: 'mutation', useCaso: () => useEliminarGrupoPrecioMutation(), args: '1' },
  { nombre: 'useToggleGrupoPrecioActivoMutation', tipo: 'mutation', useCaso: () => useToggleGrupoPrecioActivoMutation(), args: { id: '1', activo: false } },
  { nombre: 'useActualizarPrecioEscalaMutation', tipo: 'mutation', useCaso: () => useActualizarPrecioEscalaMutation(), args: { escalaId: '1', productoId: '2', precio: 9, alcance: 'grupo' } },
  { nombre: 'useAgregarProductoACondicionMutation', tipo: 'mutation', useCaso: () => useAgregarProductoACondicionMutation(), args: { grupoId: '1', productoId: '2' } },
  { nombre: 'useQuitarProductoDeCondicionMutation', tipo: 'mutation', useCaso: () => useQuitarProductoDeCondicionMutation(), args: { grupoId: '1', productoId: '2' } },
  { nombre: 'useCrearEscalaMutation', tipo: 'mutation', useCaso: () => useCrearEscalaMutation(), args: { grupoId: '1', cantidadMinima: 3, precioUnitario: 4 } },
  { nombre: 'useActualizarEscalaMutation', tipo: 'mutation', useCaso: () => useActualizarEscalaMutation(), args: { escalaId: '1', cantidadMinima: 3 } },
  { nombre: 'useEliminarEscalaMutation', tipo: 'mutation', useCaso: () => useEliminarEscalaMutation(), args: { escalaId: '1' } },
  { nombre: 'useCrearCondicionParaProductoMutation', tipo: 'mutation', useCaso: () => useCrearCondicionParaProductoMutation(), args: { productoId: '1', cantidadMinima: 2, precioUnitario: 3 } },
  { nombre: 'useConsolidarCondicionesMutation', tipo: 'mutation', useCaso: () => useConsolidarCondicionesMutation(), args: { grupoDestino: '1', gruposOrigen: ['2'] } },
  // usePromocionesQuery
  { nombre: 'usePromocionesListQuery', tipo: 'query', useCaso: () => usePromocionesListQuery() },
  { nombre: 'usePedidoSustitucionesQuery', tipo: 'query', useCaso: () => usePedidoSustitucionesQuery('9') },
  { nombre: 'usePreviewCambioFactorQuery', tipo: 'query', useCaso: () => usePreviewCambioFactorQuery('3', 2, 2, true) },
  { nombre: 'useCrearPromocionMutation', tipo: 'mutation', useCaso: () => useCrearPromocionMutation(), args: promoInput },
  { nombre: 'useActualizarPromocionMutation', tipo: 'mutation', useCaso: () => useActualizarPromocionMutation(), args: { id: '1', data: promoInput } },
  { nombre: 'useEliminarPromocionMutation', tipo: 'mutation', useCaso: () => useEliminarPromocionMutation(), args: '1' },
  { nombre: 'useTogglePromocionActivaMutation', tipo: 'mutation', useCaso: () => useTogglePromocionActivaMutation(), args: { id: '1', activo: false } },
  { nombre: 'useAjustarStockPromoMutation', tipo: 'mutation', useCaso: () => useAjustarStockPromoMutation(), args: { promocionId: '1', productoRegaloId: '2', cantidadStock: 1, usosAjustados: 1, usuarioId: 'u' } },
  { nombre: 'contarReferenciasDePromocion', tipo: 'mutation', useCaso: () => ({ mutateAsync: (id: string) => contarReferenciasDePromocion(id) }), args: '1' },
  // useImpuestosInternosQuery
  { nombre: 'useCatalogoIIQuery', tipo: 'query', useCaso: () => useCatalogoIIQuery() },
  { nombre: 'useGuardarEncuadreIIMutation', tipo: 'mutation', useCaso: () => useGuardarEncuadreIIMutation(), args: { data: { nombre: 'E' } } },
  { nombre: 'useCambiarAlicuotaIIMutation', tipo: 'mutation', useCaso: () => useCambiarAlicuotaIIMutation(), args: { encuadreId: '1', tasaNominal: 0.1, vigenteDesde: '2026-01-01' } },
  { nombre: 'useCancelarAlicuotaProgramadaMutation', tipo: 'mutation', useCaso: () => useCancelarAlicuotaProgramadaMutation(), args: '3' },
  // useCargosCatalogoQuery
  { nombre: 'useCargoConceptosQuery', tipo: 'query', useCaso: () => useCargoConceptosQuery() },
  { nombre: 'useCargoMedidasQuery', tipo: 'query', useCaso: () => useCargoMedidasQuery() },
  { nombre: 'useProductoMedidasQuery', tipo: 'query', useCaso: () => useProductoMedidasQuery() },
  { nombre: 'useGuardarProductoMedidasMutation', tipo: 'mutation', useCaso: () => useGuardarProductoMedidasMutation(), args: [{ productoId: '1', medidaId: '2', unidadesPor: 3 }] },
  // usePoliticasComercialesQuery
  { nombre: 'usePoliticasComercialesQuery', tipo: 'query', useCaso: () => usePoliticasComercialesQuery() },
  { nombre: 'useImpactoMinimoQuery', tipo: 'query', useCaso: () => useImpactoMinimoQuery(5000) },
  { nombre: 'useActualizarMontoMinimoMutation', tipo: 'mutation', useCaso: () => useActualizarMontoMinimoMutation(), args: 1000 },
  { nombre: 'useActualizarComisionesDefaultMutation', tipo: 'mutation', useCaso: () => useActualizarComisionesDefaultMutation(), args: { pctPreventista: 2, pctOtros: 0 } },
  { nombre: 'useActualizarAlertasVencimientoMutation', tipo: 'mutation', useCaso: () => useActualizarAlertasVencimientoMutation(), args: { diasAlerta: 60, diasCritico: 15 } },
  { nombre: 'useActualizarMostrarSinStockMutation', tipo: 'mutation', useCaso: () => useActualizarMostrarSinStockMutation(), args: true },
  // useMermasReporteQuery
  { nombre: 'useMermasReporteQuery', tipo: 'query', useCaso: () => useMermasReporteQuery(2, '2026-01-01', '2026-01-31') },
]

async function capturar(caso: Caso): Promise<unknown> {
  const { result } = renderHook(() => caso.useCaso(), { wrapper: wrapper() })
  if (caso.tipo === 'query') {
    await waitFor(() => expect((result.current as { isError: boolean }).isError).toBe(true))
    return (result.current as { error: unknown }).error
  }
  let capturado: unknown
  await (result.current as { mutateAsync: (a: unknown) => Promise<unknown> })
    .mutateAsync(caso.args)
    .then(() => { throw new Error('la mutación debía fallar') }, (e: unknown) => { capturado = e })
  return capturado
}

describe('catálogo: el error de supabase llega como Error y no se pierde (#760)', () => {
  beforeEach(() => { estado.error = null })

  describe.each(casos.map(c => [c.nombre, c] as const))('%s', (_n, caso) => {
    it('con error del servidor: Error con el mismo message y el code conservado', async () => {
      estado.error = ERROR_SERVIDOR
      const e = await capturar(caso)
      expect(e).toBeInstanceOf(Error)
      expect((e as Error).message).toBe(ERROR_SERVIDOR.message)
      expect((e as { code?: string }).code).toBe('P0001')
      expect((e as { details?: string }).details).toBe('detalle del servidor')
      expect((e as { hint?: string }).hint).toBe('pista del servidor')
      expect(isTransientNetworkError(e)).toBe(false)
    })

    it('sin red: mensaje de sin conexión (no "Failed to fetch") y sigue siendo transitorio', async () => {
      estado.error = ERROR_RED
      const e = await capturar(caso)
      expect(e).toBeInstanceOf(Error)
      expect((e as Error).message).toMatch(/^Sin conexión: /)
      expect((e as Error).message).not.toMatch(/failed to fetch/i)
      expect(isTransientNetworkError(e)).toBe(true)
    })
  })
})

describe('useProductos (hook legado de useState): tira Error, no el objeto plano', () => {
  beforeEach(() => { estado.error = null })

  type Hook = ReturnType<typeof useProductos>
  const acciones: Array<[string, (h: Hook) => Promise<unknown>]> = [
    ['agregarProducto', h => h.agregarProducto({ nombre: 'x', precio: 1, stock: 1 } as never)],
    ['actualizarProducto', h => h.actualizarProducto('1', { nombre: 'y' })],
    ['eliminarProducto', h => h.eliminarProducto('1')],
    ['descontarStock', h => h.descontarStock([{ productoId: '1', cantidad: 1 }])],
  ]

  it.each(acciones)('%s', async (_n, accion) => {
    const { result } = renderHook(() => useProductos())
    await waitFor(() => expect(result.current.loading).toBe(false))

    estado.error = ERROR_SERVIDOR
    const eServidor = await accion(result.current).then(() => null, (e: unknown) => e)
    expect(eServidor).toBeInstanceOf(Error)
    expect((eServidor as Error).message).toBe(ERROR_SERVIDOR.message)
    expect((eServidor as { code?: string }).code).toBe('P0001')

    estado.error = ERROR_RED
    const eRed = await accion(result.current).then(() => null, (e: unknown) => e)
    expect(eRed).toBeInstanceOf(Error)
    expect((eRed as Error).message).toMatch(/^Sin conexión: /)
    expect(isTransientNetworkError(eRed)).toBe(true)
  })
})

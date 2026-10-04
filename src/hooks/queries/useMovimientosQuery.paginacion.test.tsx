/**
 * `useMovimientosQuery` pagina en el servidor (WP-51, #775).
 *
 * El hook ya pedia una pagina de `MOVIMIENTOS_PAGE_SIZE` con `.range()`, pero
 * nadie le pasaba `pagina` y no sabia cuantas habia. Ahora pide el conteo exacto
 * en la MISMA consulta (`{ count: 'exact' }`, sin migracion) y lo devuelve como
 * `total`, junto con las filas de la pagina en `data`.
 *
 * Que fijan estos tests:
 *  - pasar de pagina pide el `range` siguiente;
 *  - el total sale del `count` del servidor, no de las filas que llegaron;
 *  - la pagina forma parte de la queryKey (cada pagina es su propio cache);
 *  - `data` sigue siendo el array de la pagina (la forma de siempre);
 *  - pedir una pagina que ya no existe (se resolvio el ultimo movimiento de la
 *    ultima pagina) no es un error: vuelve vacia con el total, para que el
 *    container retroceda;
 *  - mientras llega la pagina siguiente se ven los datos de la anterior, pero al
 *    cambiar de pestaña NO se muestran los de la otra lista.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

interface Respuesta {
  data: unknown[] | null
  error: { message: string; code?: string } | null
  count: number | null
}

interface Llamada {
  select: { cols: string; opciones: unknown }
  rango: [number, number]
  filtros: Array<[string, unknown]>
}

const llamadas: Llamada[] = []
/** Cada test decide que contesta el "servidor" para un rango dado. */
let responder: (rango: [number, number], llamada: Llamada) => Respuesta | Promise<Respuesta>

const from = vi.fn((tabla: string) => {
  expect(tabla).toBe('movimientos_sucursal')
  const llamada: Llamada = { select: { cols: '', opciones: undefined }, rango: [-1, -1], filtros: [] }
  const b: Record<string, unknown> = {}
  b.select = (cols: string, opciones?: unknown) => { llamada.select = { cols, opciones }; return b }
  b.order = () => b
  b.range = (d: number, h: number) => { llamada.rango = [d, h]; return b }
  for (const metodo of ['gte', 'lte', 'eq']) {
    b[metodo] = (col: string, valor: unknown) => { llamada.filtros.push([`${metodo}:${col}`, valor]); return b }
  }
  // Es await-eable como el builder de supabase-js: la llamada se anota al awaitear.
  b.then = (ok: (r: Respuesta) => unknown, ko: (e: unknown) => unknown) => {
    llamadas.push(llamada)
    return Promise.resolve(responder(llamada.rango, llamada)).then(ok, ko)
  }
  return b
})

vi.mock('../supabase/base', () => ({
  supabase: { from: (...args: unknown[]) => from(...(args as [string])), rpc: vi.fn() },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useMovimientosQuery, MOVIMIENTOS_PAGE_SIZE, movimientosKeys } from './useMovimientosQuery'
import type { MovimientosFiltros } from './useMovimientosQuery'

function fila(id: number) {
  return { id, estado: 'pendiente' }
}

/** Una pagina del servidor con ids `desde..hasta` (inclusive) y un total dado. */
function pagina(desde: number, hasta: number, count: number): Respuesta {
  return {
    data: Array.from({ length: Math.max(0, hasta - desde + 1) }, (_, i) => fila(desde + i)),
    error: null,
    count,
  }
}

function envolver() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return { qc, wrapper }
}

function montar(inicial: MovimientosFiltros) {
  const { qc, wrapper } = envolver()
  const hook = renderHook((filtros: MovimientosFiltros) => useMovimientosQuery(filtros), {
    wrapper,
    initialProps: inicial,
  })
  return { qc, ...hook }
}

beforeEach(() => {
  llamadas.length = 0
  from.mockClear()
  responder = () => pagina(1, 0, 0)
})

describe('useMovimientosQuery — pagina y total', () => {
  it('la pagina 1 pide el rango 0-49 con el conteo exacto', async () => {
    responder = (r) => pagina(r[0] + 1, r[1] + 1, 120)
    const { result } = montar({ estado: 'pendiente', pagina: 1 })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(llamadas).toHaveLength(1)
    expect(llamadas[0].rango).toEqual([0, MOVIMIENTOS_PAGE_SIZE - 1])
    expect(llamadas[0].select.opciones).toEqual({ count: 'exact' })
  })

  it('pasar a la pagina 2 pide el rango siguiente (50-99)', async () => {
    responder = (r) => pagina(r[0] + 1, r[1] + 1, 120)
    const { result, rerender } = montar({ estado: 'pendiente', pagina: 1 })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    rerender({ estado: 'pendiente', pagina: 2 })
    await waitFor(() => expect(llamadas).toHaveLength(2))
    expect(llamadas[1].rango).toEqual([MOVIMIENTOS_PAGE_SIZE, 2 * MOVIMIENTOS_PAGE_SIZE - 1])

    rerender({ estado: 'pendiente', pagina: 3 })
    await waitFor(() => expect(llamadas).toHaveLength(3))
    expect(llamadas[2].rango).toEqual([2 * MOVIMIENTOS_PAGE_SIZE, 3 * MOVIMIENTOS_PAGE_SIZE - 1])
  })

  it('el total sale del count del servidor, no de las filas que llegaron', async () => {
    // Llegan 50 filas, pero hay 120 movimientos en total.
    responder = () => pagina(1, 50, 120)
    const { result } = montar({ estado: 'pendiente', pagina: 1 })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(result.current.data).toHaveLength(50)
    expect(result.current.total).toBe(120)
  })

  it('en la ultima pagina llegan menos filas y el total sigue siendo el de toda la lista', async () => {
    responder = () => pagina(101, 120, 120)
    const { result } = montar({ estado: 'pendiente', pagina: 3 })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(result.current.data).toHaveLength(20)
    expect(result.current.total).toBe(120)
  })

  it('`data` sigue siendo el array de filas de la pagina', async () => {
    responder = () => pagina(1, 3, 3)
    const { result } = montar({ estado: 'todos' })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(Array.isArray(result.current.data)).toBe(true)
    expect(result.current.data!.map(m => m.id)).toEqual([1, 2, 3])
  })

  it('antes de que llegue algo, data es undefined y el total es 0', () => {
    responder = () => new Promise<Respuesta>(() => undefined)
    const { result } = montar({ estado: 'pendiente', pagina: 1 })
    expect(result.current.data).toBeUndefined()
    expect(result.current.total).toBe(0)
    expect(result.current.isLoading).toBe(true)
  })

  it('un count nulo cuenta como 0', async () => {
    responder = () => ({ data: [], error: null, count: null })
    const { result } = montar({ estado: 'pendiente' })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.total).toBe(0)
    expect(result.current.data).toEqual([])
  })

  it('el estado pedido llega como filtro `eq` y "todos" no filtra', async () => {
    const { result, rerender } = montar({ estado: 'aceptada' })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(llamadas[0].filtros).toContainEqual(['eq:estado', 'aceptada'])

    rerender({ estado: 'todos' })
    await waitFor(() => expect(llamadas).toHaveLength(2))
    expect(llamadas[1].filtros.some(([k]) => k === 'eq:estado')).toBe(false)
  })
})

describe('useMovimientosQuery — queryKey', () => {
  it('la pagina forma parte de la key: cada pagina es su propia entrada de cache', async () => {
    responder = (r) => pagina(r[0] + 1, r[1] + 1, 120)
    const { qc, result, rerender } = montar({ estado: 'pendiente', pagina: 1 })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    rerender({ estado: 'pendiente', pagina: 2 })
    await waitFor(() => expect(llamadas).toHaveLength(2))

    const keys = qc.getQueryCache().findAll({ queryKey: movimientosKeys.lists(1) }).map(q => q.queryKey)
    expect(keys).toHaveLength(2)
    const paginas = keys.map(k => (k[3] as { pagina: number }).pagina).sort()
    expect(paginas).toEqual([1, 2])
  })

  it('volver a una pagina ya vista sale del cache y no pide de nuevo', async () => {
    responder = (r) => pagina(r[0] + 1, r[1] + 1, 120)
    const { result, rerender } = montar({ estado: 'pendiente', pagina: 1 })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    rerender({ estado: 'pendiente', pagina: 2 })
    await waitFor(() => expect(llamadas).toHaveLength(2))

    rerender({ estado: 'pendiente', pagina: 1 })
    await waitFor(() => expect(result.current.data?.[0]).toEqual(fila(1)))
    expect(llamadas).toHaveLength(2)
  })

  it('el estado tambien forma parte de la key', async () => {
    responder = () => pagina(1, 2, 2)
    const { qc, result, rerender } = montar({ estado: 'pendiente', pagina: 1 })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    rerender({ estado: 'aceptada', pagina: 1 })
    await waitFor(() => expect(llamadas).toHaveLength(2))
    expect(qc.getQueryCache().findAll({ queryKey: movimientosKeys.lists(1) })).toHaveLength(2)
  })
})

describe('useMovimientosQuery — pedir una pagina que ya no existe', () => {
  it('el 416 de PostgREST (PGRST103) vuelve como pagina vacia con el total real', async () => {
    // 60 movimientos = 2 paginas; se pide la 3 (offset 100), que ya no existe.
    responder = (r) =>
      r[0] === 100
        ? { data: null, error: { message: 'Requested range not satisfiable', code: 'PGRST103' }, count: null }
        : pagina(1, 1, 60)
    const { result } = montar({ estado: 'pendiente', pagina: 3 })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(result.current.data).toEqual([])
    expect(result.current.total).toBe(60)
    // Primero la pagina pedida, despues una fila de la primera solo para el conteo.
    expect(llamadas.map(l => l.rango)).toEqual([[100, 149], [0, 0]])
  })

  it('un error de rango en la pagina 1 NO se disfraza: se propaga', async () => {
    responder = () => ({ data: null, error: { message: 'rango invalido', code: 'PGRST103' }, count: null })
    const { result } = montar({ estado: 'pendiente', pagina: 1 })
    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(llamadas).toHaveLength(1)
  })

  it('cualquier otro error se propaga', async () => {
    responder = () => ({ data: null, error: { message: 'boom', code: '500' }, count: null })
    const { result } = montar({ estado: 'pendiente', pagina: 2 })
    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(llamadas).toHaveLength(1)
  })

  it('si la tabla no existe (entorno viejo) devuelve vacio sin error', async () => {
    responder = () => ({ data: null, error: { message: 'relation "movimientos_sucursal" does not exist' }, count: null })
    const { result } = montar({ estado: 'pendiente' })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data).toEqual([])
    expect(result.current.total).toBe(0)
  })
})

describe('useMovimientosQuery — mientras llega la pagina siguiente', () => {
  it('se siguen viendo las filas y el total de la pagina anterior', async () => {
    let soltarPagina2: (r: Respuesta) => void = () => undefined
    responder = (r) =>
      r[0] === 0
        ? pagina(1, 50, 120)
        : new Promise<Respuesta>(res => { soltarPagina2 = res })
    const { result, rerender } = montar({ estado: 'pendiente', pagina: 1 })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    rerender({ estado: 'pendiente', pagina: 2 })
    await waitFor(() => expect(result.current.isPlaceholderData).toBe(true))
    expect(result.current.isLoading).toBe(false)
    expect(result.current.data).toHaveLength(50)
    expect(result.current.total).toBe(120)

    await act(async () => { soltarPagina2(pagina(51, 100, 120)) })
    await waitFor(() => expect(result.current.isPlaceholderData).toBe(false))
    expect(result.current.data![0]).toEqual(fila(51))
  })

  it('al cambiar de pestaña NO se muestran las filas de la otra lista', async () => {
    responder = (r, l) =>
      l.filtros.some(([k, v]) => k === 'eq:estado' && v === 'aceptada')
        ? new Promise<Respuesta>(() => undefined)
        : pagina(r[0] + 1, r[1] + 1, 120)
    const { result, rerender } = montar({ estado: 'pendiente', pagina: 1 })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    rerender({ estado: 'aceptada', pagina: 1 })
    await waitFor(() => expect(llamadas).toHaveLength(2))
    expect(result.current.isPlaceholderData).toBe(false)
    expect(result.current.isLoading).toBe(true)
    expect(result.current.data).toBeUndefined()
    expect(result.current.total).toBe(0)
  })
})

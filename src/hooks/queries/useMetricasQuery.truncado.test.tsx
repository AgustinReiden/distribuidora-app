/**
 * Tests del truncado silencioso en el dashboard (#524).
 *
 * QUÉ PASABA
 * ----------
 * PostgREST corta en 1.000 filas y devuelve 200. La query principal del
 * dashboard se paginó en el PR #525, pero las otras dos del mismo `Promise.all`
 * quedaron sin paginar, y una de ellas ya truncaba en prod:
 *
 *   - "período anterior": tiene la MISMA duración que el período elegido, así
 *     que con "mes" son 1.064 pedidos y llegaban 1.000. La tarjeta de ventas
 *     compara el período actual (completo) contra ese anterior (recortado), o
 *     sea que la flechita de tendencia exageraba el crecimiento: $43,4M en vez
 *     de $46,3M, un 93,8% del real, y la distorsión crece con el volumen.
 *   - la serie de 7 días: hoy son ~213 pedidos, no trunca. Lo que la salva es
 *     el volumen, no el código.
 *
 * Y como ninguna de las dos tenía `order`, cuáles 1.000 llegaban no estaba
 * definido: dos cargas del mismo dashboard podían dar números distintos.
 *
 * QUÉ FIJAN ESTOS TESTS
 * ---------------------
 * Que las tres consultas de pedidos se paginen (terminan en `.range()`, no en
 * un await pelado) y que todas lleven un orden estable terminado en `id`
 * —paginar con `range()` sin ORDER BY único repite filas y saltea otras—.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const from = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (...args: unknown[]) => from(...args),
    rpc: vi.fn(),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useMetricasQuery } from './useMetricasQuery'

/** Una consulta observada: qué columnas pidió, cómo ordenó, qué rangos trajo. */
interface Consulta {
  select: string
  orders: string[]
  rangos: Array<[number, number]>
  /** true si se resolvió con un await directo, sin pasar por `.range()`. */
  awaitDirecto: boolean
}

/**
 * Las consultas se agrupan por su `select`, que es lo que las distingue. Hace
 * falta porque `traerTodo` llama a la factory UNA VEZ POR PAGINA: cada pagina
 * crea un builder nuevo, y si se contara por builder saldrian seis consultas
 * de una linea en vez de tres de dos paginas.
 */
let consultas = new Map<string, Consulta>()

function registrar(select: string): Consulta {
  const yaVista = consultas.get(select)
  if (yaVista) return yaVista
  const nueva: Consulta = { select, orders: [], rangos: [], awaitDirecto: false }
  consultas.set(select, nueva)
  return nueva
}

/**
 * Builder encadenable que ademas ANOTA lo que le piden.
 *
 * La primera pagina vuelve LLENA (tantas filas como entren en el rango pedido),
 * que es la unica senal que tiene el paginador para saber que puede haber mas;
 * la segunda vuelve vacia y ahi corta. O sea: simula una tabla que no entra en
 * una sola pagina, que es el caso que importa. El `.then` esta para detectar el
 * caso viejo —una consulta que se await-ea sin paginar—.
 */
function armarBuilder() {
  // Se registra recién en `.select()`: registrar antes dejaría una consulta
  // fantasma, sin rangos ni orders, que hace fallar a las aserciones "las tres".
  let consulta: Consulta = { select: '(sin select)', orders: [], rangos: [], awaitDirecto: false }

  const fila = { id: 1, total: 100, estado: 'entregado', fecha: '2026-09-01', items: [] }
  const builder: Record<string, unknown> = {}
  const encadenable = () => builder

  builder.select = (cols: string) => { consulta = registrar(cols); return builder }
  builder.order = (col: string) => {
    // Los `order` se anotan una sola vez: se repiten en cada pagina.
    if (consulta.rangos.length === 0 && !consulta.orders.includes(col)) consulta.orders.push(col)
    return builder
  }
  builder.eq = encadenable
  builder.neq = encadenable
  builder.gte = encadenable
  builder.lte = encadenable
  builder.range = (desde: number, hasta: number) => {
    consulta.rangos.push([desde, hasta])
    const filas = desde === 0
      ? Array.from({ length: hasta - desde + 1 }, () => fila)
      : []
    return Promise.resolve({ data: filas, error: null })
  }
  // Si alguien await-ea el builder sin `.range()`, cae aca: es exactamente la
  // forma que tenia el bug.
  builder.then = (resolver: (v: unknown) => unknown) => {
    consulta.awaitDirecto = true
    return Promise.resolve({ data: [fila], error: null }).then(resolver)
  }
  return builder
}

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

function nuevoQueryClient() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } })
}

/** Corre el hook con período "mes", que es el que dispara el período anterior. */
async function correrDashboard(): Promise<Consulta[]> {
  consultas = new Map()
  from.mockImplementation(() => armarBuilder())
  const qc = nuevoQueryClient()
  const { result } = renderHook(() => useMetricasQuery('mes'), {
    wrapper: makeWrapper(qc),
  })
  await waitFor(() => expect(result.current.isSuccess).toBe(true))
  return [...consultas.values()]
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe('useMetricasQuery — truncado silencioso', () => {
  it('hace las tres consultas de pedidos del dashboard', async () => {
    const consultas = await correrDashboard()
    // principal (con items), período anterior (total, estado), serie (total, fecha)
    expect(consultas).toHaveLength(3)
  })

  describe('ninguna consulta se resuelve sin paginar', () => {
    it('las tres pasan por .range()', async () => {
      const consultas = await correrDashboard()
      for (const c of consultas) {
        expect(c.rangos.length).toBeGreaterThan(0)
      }
    })

    it('ninguna se await-ea directo, que era la forma del bug', async () => {
      const consultas = await correrDashboard()
      expect(consultas.filter(c => c.awaitDirecto)).toEqual([])
    })
  })

  describe('el período anterior trae todo, no la primera página', () => {
    it('sigue pidiendo páginas mientras vengan llenas', async () => {
      // Una página llena obliga a pedir la siguiente: es lo que no pasaba.
      const consultas = await correrDashboard()
      const anterior = consultas.find(c => c.select === 'total, estado')
      expect(anterior?.rangos).toHaveLength(2)
    })

    it('la serie de 7 días también', async () => {
      const consultas = await correrDashboard()
      const serie = consultas.find(c => c.select === 'total, fecha')
      expect(serie?.rangos).toHaveLength(2)
    })
  })

  describe('el orden es estable, o la paginación miente', () => {
    it('las tres desempatan por id', async () => {
      const consultas = await correrDashboard()
      for (const c of consultas) {
        expect(c.orders[c.orders.length - 1]).toBe('id')
      }
    })

    it('la principal ordena por created_at antes del desempate', async () => {
      const consultas = await correrDashboard()
      const principal = consultas.find(c => c.select.includes('items:pedido_items'))
      expect(principal?.orders).toEqual(['created_at', 'id'])
    })
  })
})

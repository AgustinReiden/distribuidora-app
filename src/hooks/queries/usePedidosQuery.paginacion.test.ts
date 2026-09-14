/**
 * `fetchPedidosAsignados`, `fetchPedidosNoEntregados`,
 * `fetchPedidosParaEntregaYPago` y `fetchPedidosNoPagados` leían sin `range`:
 * PostgREST corta en 1.000 filas y devuelve un 200, así que un preventista con
 * más de 1.000 pedidos sin entregar (o sin pagar) veía una lista incompleta
 * sin ningún error (#524). Este test prueba que las cuatro pasan por
 * `traerTodo` y juntan una segunda página en vez de quedarse con la primera.
 */
import { describe, it, expect, vi } from 'vitest'

const PAGINA = 1000

/** Fila mínima de `pedidos` que necesitan estas cuatro funciones. */
function pedidoDe(id: number) {
  return { id, estado: 'pendiente', estado_pago: 'pendiente', transportista_id: null, cliente: null }
}

/**
 * Mock de `supabase.from('pedidos')...`: cualquier combinación de
 * `.select/.eq/.neq/.not/.or/.in/.order` encadena sobre el mismo objeto (como
 * supabase-js) y `.range` corta el array en memoria, igual que haría
 * PostgREST con `Range`.
 */
function fakeSupabase(pedidosTotales: number) {
  const rangos: Array<[number, number]> = []
  const filas = Array.from({ length: pedidosTotales }, (_, i) => pedidoDe(i + 1))

  const pedidosBuilder: Record<string, unknown> = {}
  for (const metodo of ['select', 'eq', 'neq', 'not', 'or', 'in', 'order']) {
    pedidosBuilder[metodo] = () => pedidosBuilder
  }
  pedidosBuilder.range = (desde: number, hasta: number) => {
    rangos.push([desde, hasta])
    return Promise.resolve({ data: filas.slice(desde, hasta + 1), error: null })
  }

  const perfilesBuilder = {
    select: () => perfilesBuilder,
    in: () => Promise.resolve({ data: [], error: null }),
  }

  const from = vi.fn((tabla: string) => (tabla === 'pedidos' ? pedidosBuilder : perfilesBuilder))
  return { supabase: { from }, rangos }
}

describe('paginado de las listas "sin paginación" de pedidos', () => {
  it.each([
    ['fetchPedidosAsignados', (m: typeof import('./usePedidosQuery')) => m.fetchPedidosAsignados(1)],
    ['fetchPedidosNoEntregados', (m: typeof import('./usePedidosQuery')) => m.fetchPedidosNoEntregados(1)],
    ['fetchPedidosParaEntregaYPago', (m: typeof import('./usePedidosQuery')) => m.fetchPedidosParaEntregaYPago(1)],
    ['fetchPedidosNoPagados', (m: typeof import('./usePedidosQuery')) => m.fetchPedidosNoPagados(1)],
  ])('%s junta la segunda página en vez de cortar en %d filas', async (_nombre, llamar) => {
    vi.resetModules()
    const { supabase, rangos } = fakeSupabase(PAGINA + 250)
    vi.doMock('../supabase/base', () => ({ supabase }))
    vi.doMock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))

    const mod = await import('./usePedidosQuery')
    const resultado = await llamar(mod)

    expect(resultado).toHaveLength(PAGINA + 250)
    // Sin `range`, esta lista tendría un solo pedido a rangos: nunca hubiera
    // una segunda página.
    expect(rangos.length).toBeGreaterThanOrEqual(2)
    expect(rangos[0]).toEqual([0, PAGINA - 1])
    expect(rangos[1][0]).toBe(PAGINA)

    vi.doUnmock('../supabase/base')
    vi.doUnmock('../../contexts/SucursalContext')
  })
})

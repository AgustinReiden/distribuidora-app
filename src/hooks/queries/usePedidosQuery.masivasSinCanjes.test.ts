/**
 * #1318: la comanda de un canje (`canal = 'cambio'`) no se entrega en masa.
 * Se entrega desde el pedido, que aplica el cambio de producto
 * (`aplicar_cambio_de_parada`) antes de cerrarla, y las dos RPCs masivas la
 * saltean. Las listas de los dos modales masivos tampoco la ofrecen: si no,
 * el toast contaba como entregado un canje que la RPC dejó pendiente.
 */
import { describe, it, expect, vi } from 'vitest'

function fakeSupabase(filas: Array<Record<string, unknown>>) {
  const pedidosBuilder: Record<string, unknown> = {}
  for (const metodo of ['select', 'eq', 'neq', 'not', 'or', 'in', 'order']) {
    pedidosBuilder[metodo] = () => pedidosBuilder
  }
  pedidosBuilder.range = (desde: number, hasta: number) =>
    Promise.resolve({ data: filas.slice(desde, hasta + 1), error: null })

  const perfilesBuilder = {
    select: () => perfilesBuilder,
    in: () => Promise.resolve({ data: [], error: null }),
  }
  return { from: vi.fn((tabla: string) => (tabla === 'pedidos' ? pedidosBuilder : perfilesBuilder)) }
}

const FILAS = [
  { id: 1, canal: 'app', estado: 'asignado', estado_pago: 'pendiente', transportista_id: null, cliente: null },
  { id: 2, canal: 'cambio', estado: 'asignado', estado_pago: 'pendiente', transportista_id: null, cliente: null },
  { id: 3, canal: 'bot', estado: 'pendiente', estado_pago: 'pendiente', transportista_id: null, cliente: null },
]

describe('las listas de las entregas masivas no traen canjes (#1318)', () => {
  it.each([
    ['fetchPedidosNoEntregados', (m: typeof import('./usePedidosQuery')) => m.fetchPedidosNoEntregados(1)],
    ['fetchPedidosParaEntregaYPago', (m: typeof import('./usePedidosQuery')) => m.fetchPedidosParaEntregaYPago(1)],
  ])('%s deja afuera la comanda del canje', async (_nombre, llamar) => {
    vi.resetModules()
    vi.doMock('../supabase/base', () => ({ supabase: fakeSupabase(FILAS) }))
    vi.doMock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))

    const mod = await import('./usePedidosQuery')
    const resultado = await llamar(mod)

    expect(resultado.map(p => p.id)).toEqual([1, 3])

    vi.doUnmock('../supabase/base')
    vi.doUnmock('../../contexts/SucursalContext')
  })
})

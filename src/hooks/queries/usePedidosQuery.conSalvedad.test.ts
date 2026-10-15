/**
 * `fetchPedidoIdsConSalvedad` alimenta el filtro "Con salvedad", las cards de
 * stats y el export. Una salvedad anulada deshace todo: un pedido que sólo
 * tiene anuladas no es "con salvedad" (#1180).
 */
import { describe, it, expect, vi } from 'vitest'

type Fila = { pedido_id: number; estado_resolucion: string }

const FILAS: Fila[] = [
  { pedido_id: 910, estado_resolucion: 'anulada' },
  { pedido_id: 910, estado_resolucion: 'anulada' },
  { pedido_id: 3408, estado_resolucion: 'anulada' },
  { pedido_id: 3408, estado_resolucion: 'pendiente' },
  { pedido_id: 5599, estado_resolucion: 'anulada' },
  { pedido_id: 700, estado_resolucion: 'pendiente' },
  { pedido_id: 700, estado_resolucion: 'nota_credito' },
]

function fakeSupabase(filas: Fila[]) {
  const neqLlamadas: Array<[string, string]> = []
  let visibles = filas
  const builder: Record<string, unknown> = {}
  builder.select = () => builder
  builder.neq = (col: string, valor: string) => {
    neqLlamadas.push([col, valor])
    visibles = visibles.filter(f => (f as Record<string, unknown>)[col] !== valor)
    return builder
  }
  builder.order = () => builder
  builder.range = (desde: number, hasta: number) =>
    Promise.resolve({ data: visibles.slice(desde, hasta + 1), error: null })
  const from = vi.fn(() => builder)
  return { supabase: { from }, neqLlamadas }
}

async function correr(filas: Fila[]) {
  vi.resetModules()
  const { supabase, neqLlamadas } = fakeSupabase(filas)
  vi.doMock('../supabase/base', () => ({ supabase }))
  vi.doMock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))
  const mod = await import('./usePedidosQuery')
  const ids = await mod.fetchPedidoIdsConSalvedad()
  vi.doUnmock('../supabase/base')
  vi.doUnmock('../../contexts/SucursalContext')
  return { ids, neqLlamadas }
}

describe('fetchPedidoIdsConSalvedad', () => {
  it('no cuenta los pedidos cuyas salvedades están todas anuladas, sin duplicados', async () => {
    const { ids } = await correr(FILAS)
    expect(ids.sort((a, b) => a - b)).toEqual([700, 3408])
  })

  it('excluye las anuladas con neq(estado_resolucion, anulada)', async () => {
    const { neqLlamadas } = await correr(FILAS)
    expect(neqLlamadas).toContainEqual(['estado_resolucion', 'anulada'])
  })

  it('si todas son anuladas devuelve []', async () => {
    const { ids } = await correr(FILAS.filter(f => f.estado_resolucion === 'anulada'))
    expect(ids).toEqual([])
  })
})

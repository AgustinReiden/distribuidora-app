/**
 * H-4 de la lente de H (tanda 6 bis de #1603): un preventista con el extra de chofer ve por RLS
 * también las boletas que reparte y no vendió. Las notas de esas boletas no le llegan (la RPC
 * `notas_credito_venta_del_vendedor` le da sólo las de SUS ventas), así que ese pedazo de su
 * «Total comprado» quedaba bruto. Ahora, con `vendedorId`, la ficha cuenta sólo las boletas que él
 * vendió (`pedidos.usuario_id`), y las restas de la RPC cierran contra eso.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'

const m = vi.hoisted(() => ({
  livianos: [] as Array<Record<string, unknown>>,
  selectPedidos: [] as string[],
  delVendedor: [] as Array<Record<string, unknown>>,
}))

vi.mock('./base', () => {
  const tabla = (nombre: string) => {
    const builder: Record<string, unknown> = {}
    const enc = () => builder
    builder.select = (cols: string) => { if (nombre === 'pedidos') m.selectPedidos.push(cols); return builder }
    builder.eq = enc
    builder.order = enc
    builder.range = () => Promise.resolve({ data: nombre === 'pedidos' ? m.livianos : [], error: null })
    builder.limit = () => Promise.resolve({ data: [], error: null })
    return builder
  }
  const rpc = () => {
    const builder: Record<string, unknown> = {}
    builder.range = () => Promise.resolve({ data: m.delVendedor, error: null })
    return builder
  }
  return { supabase: { from: (n: string) => tabla(n), rpc }, notifyError: vi.fn() }
})

import { useFichaCliente } from './useFichaCliente'

const ped = (over: Record<string, unknown>) => ({
  cliente_id: '440', estado: 'entregado', estado_pago: 'pagado', canal: 'app',
  fecha: '2026-10-01', created_at: '2026-10-01T15:00:00Z', tipo_factura: 'ZZ', total: 0, cargo_envio: 0,
  usuario_id: 'pre-1', ...over,
})

async function ficha(vendedorId?: string | null) {
  const { result } = renderHook(() => useFichaCliente('440', vendedorId))
  await waitFor(() => expect(result.current.estadisticas).not.toBeNull())
  return result.current.estadisticas!
}

beforeEach(() => {
  m.selectPedidos = []
  // El preventista le vendió 1.050 en dos boletas; una tercera de $ 500 la vendió otro y él la reparte.
  m.livianos = [
    ped({ id: '1', total: 600 }),
    ped({ id: '2', total: 450 }),
    ped({ id: '3', total: 500, usuario_id: 'pre-2' }),
  ]
  // La RPC le da la nota de $ 350 de una boleta suya.
  m.delVendedor = [{ fecha: '2026-10-01', cliente_id: 440, total: 350 }]
})

describe('useFichaCliente — el «Total comprado» del preventista es lo que ÉL vendió (H-4)', () => {
  it('pide quién vendió cada boleta', async () => {
    await ficha('pre-1')
    expect(m.selectPedidos[0]).toContain('usuario_id')
  })

  it('cuenta sólo sus boletas, netas de sus notas: 1.050 − 350 = 700, en 2 compras', async () => {
    const e = await ficha('pre-1')
    expect(e.totalCompras).toBe(700)
    expect(e.totalPedidos).toBe(2)
    expect(e.ticketPromedio).toBe(350)
  })

  it('sin vendedor (admin y encargado) cuenta todas las boletas del cliente', async () => {
    m.delVendedor = []
    const e = await ficha(null)
    expect(e.totalCompras).toBe(1550)
    expect(e.totalPedidos).toBe(3)
  })
})

/**
 * Ficha de cliente y vales blancos (VB): el consumo interno NO es compra.
 *
 * Un cliente de empresa propia (tipo_factura_default = 'VB') recibe vales blancos a costo.
 * En su ficha eso no cuenta como "total comprado", "compras entregadas", ticket promedio,
 * pedidos pagados ni días sin comprar: va aparte en `consumoInterno`.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'

const m = vi.hoisted(() => ({
  livianos: [] as Array<Record<string, unknown>>,
  selects: [] as string[],
}))

vi.mock('./base', () => {
  const tabla = (nombre: string) => {
    const builder: Record<string, unknown> = {}
    const enc = () => builder
    builder.select = (cols: string) => { if (nombre === 'pedidos') m.selects.push(cols); return builder }
    builder.eq = enc
    builder.order = enc
    // traerTodo (livianos y pagos) cierra con .range(); la query pesada con .limit().
    builder.range = () => Promise.resolve({ data: nombre === 'pedidos' ? m.livianos : [], error: null })
    builder.limit = () => Promise.resolve({ data: [], error: null })
    return builder
  }
  return { supabase: { from: (n: string) => tabla(n) }, notifyError: vi.fn() }
})

import { useFichaCliente } from './useFichaCliente'

const ped = (over: Record<string, unknown>) => ({
  cliente_id: '440', estado: 'entregado', estado_pago: 'pagado', canal: 'app',
  fecha: '2026-10-01', created_at: '2026-10-01T15:00:00Z', tipo_factura: 'ZZ', ...over,
})

beforeEach(() => {
  m.selects = []
})

describe('useFichaCliente — vale blanco', () => {
  it('pide tipo_factura en la query liviana (si no, el VB no se puede distinguir)', async () => {
    m.livianos = []
    const { result } = renderHook(() => useFichaCliente('440'))
    await waitFor(() => expect(result.current.estadisticas).not.toBeNull())
    expect(m.selects.some(s => s.includes('tipo_factura'))).toBe(true)
  })

  it('el VB no suma a compras, ticket ni pedidos pagados: va en consumoInterno', async () => {
    m.livianos = [
      ped({ id: '1', total: 1000 }),
      ped({ id: '2', total: 3000 }),
      ped({ id: '3', total: 8000, tipo_factura: 'VB' }),
      ped({ id: '4', total: 2000, tipo_factura: 'VB' }),
    ]
    const { result } = renderHook(() => useFichaCliente('440'))
    await waitFor(() => expect(result.current.estadisticas).not.toBeNull())

    const e = result.current.estadisticas!
    expect(e.totalCompras).toBe(4000)
    expect(e.totalPedidos).toBe(2)
    expect(e.ticketPromedio).toBe(2000)
    expect(e.pedidosPagados).toBe(2)
    expect(e.consumoInterno).toEqual({ monto: 10000, cantidad: 2 })
  })

  it('un cliente sólo-VB: sin compras, sin días desde la última compra, con consumo interno', async () => {
    m.livianos = [ped({ id: '1', total: 5000, tipo_factura: 'VB' })]
    const { result } = renderHook(() => useFichaCliente('440'))
    await waitFor(() => expect(result.current.estadisticas).not.toBeNull())

    const e = result.current.estadisticas!
    expect(e.totalCompras).toBe(0)
    expect(e.totalPedidos).toBe(0)
    expect(e.pedidosPagados).toBe(0)
    expect(e.diasDesdeUltimoPedido).toBeNull()
    expect(e.consumoInterno).toEqual({ monto: 5000, cantidad: 1 })
  })
})

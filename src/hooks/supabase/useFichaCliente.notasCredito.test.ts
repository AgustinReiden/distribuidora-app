/**
 * REP-1 (tanda 6 de #1603; decisión del dueño del 24/11): el «Total comprado» de la ficha es
 * NETO de las notas de crédito de venta del cliente, como Ventas por cliente.
 *
 * Una nota resta plata, no pedidos: las compras entregadas no cambian. La nota de una boleta
 * que no es venta (un vale blanco, un canje, un pedido sin entregar) y la anulada no restan.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'

const m = vi.hoisted(() => ({
  livianos: [] as Array<Record<string, unknown>>,
  notas: [] as Array<Record<string, unknown>>,
  consultasNotas: [] as Array<{ select: string; eqs: string[] }>,
}))

vi.mock('./base', () => {
  const tabla = (nombre: string) => {
    const builder: Record<string, unknown> = {}
    const enc = () => builder
    const consulta = { select: '', eqs: [] as string[] }
    builder.select = (cols: string) => { consulta.select = cols; if (nombre === 'notas_credito_venta') m.consultasNotas.push(consulta); return builder }
    builder.eq = (col: string, valor: unknown) => { consulta.eqs.push(`${col}:${String(valor)}`); return builder }
    builder.order = enc
    builder.range = () => Promise.resolve({
      data: nombre === 'pedidos' ? m.livianos : nombre === 'notas_credito_venta' ? m.notas : [],
      error: null,
    })
    builder.limit = () => Promise.resolve({ data: [], error: null })
    return builder
  }
  return { supabase: { from: (n: string) => tabla(n) }, notifyError: vi.fn() }
})

import { useFichaCliente } from './useFichaCliente'

const ped = (over: Record<string, unknown>) => ({
  cliente_id: '440', estado: 'entregado', estado_pago: 'pagado', canal: 'app',
  fecha: '2026-10-01', created_at: '2026-10-01T15:00:00Z', tipo_factura: 'ZZ', total: 0, cargo_envio: 0, ...over,
})

const nota = (id: number, total: number, pedido: Record<string, unknown> = {}, extra: Record<string, unknown> = {}) => ({
  id, fecha: '2026-10-01', cliente_id: 440, total, anulada: false,
  pedido: { estado: 'entregado', canal: 'app', tipo_factura: 'ZZ', usuario_id: 'u1', ...pedido },
  ...extra,
})

async function ficha() {
  const { result } = renderHook(() => useFichaCliente('440'))
  await waitFor(() => expect(result.current.estadisticas).not.toBeNull())
  return result.current.estadisticas!
}

beforeEach(() => {
  m.consultasNotas = []
  // 1.050 entregados en cuatro boletas.
  m.livianos = [ped({ id: '1', total: 200 }), ped({ id: '2', total: 300 }), ped({ id: '3', total: 400 }), ped({ id: '4', total: 150 })]
  m.notas = []
})

describe('useFichaCliente — «Total comprado» neto de notas de crédito (REP-1)', () => {
  it('lee las notas vigentes del cliente, con su boleta', async () => {
    await ficha()
    expect(m.consultasNotas).toHaveLength(1)
    expect(m.consultasNotas[0].eqs).toEqual(expect.arrayContaining(['cliente_id:440', 'anulada:false']))
    expect(m.consultasNotas[0].select).toContain('pedido:pedidos!notas_credito_venta_pedido_id_fkey(')
  })

  it('1.050 vendidos y 350 en notas dan 700 de total comprado, con las mismas 4 compras', async () => {
    m.notas = [nota(1, 100), nota(2, 100), nota(3, 100), nota(4, 50)]
    const e = await ficha()
    expect(e.totalCompras).toBe(700)
    expect(e.totalPedidos).toBe(4)
    expect(e.ticketPromedio).toBe(175)
  })

  it('sin notas es lo de siempre', async () => {
    expect((await ficha()).totalCompras).toBe(1050)
  })

  it('la nota anulada, la de un vale blanco, la de un canje y la de un pedido sin entregar no restan', async () => {
    m.notas = [
      nota(1, 100, {}, { anulada: true }),
      nota(2, 100, { tipo_factura: 'VB' }),
      nota(3, 100, { canal: 'cambio' }),
      nota(4, 50, { estado: 'asignado' }),
    ]
    expect((await ficha()).totalCompras).toBe(1050)
  })
})

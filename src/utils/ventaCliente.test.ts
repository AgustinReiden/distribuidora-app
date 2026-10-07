import { describe, it, expect } from 'vitest'
import { calcularVentaCliente, type PedidoVentaCliente } from './ventaCliente'

const pedido = (p: Partial<PedidoVentaCliente> & { id: string }): PedidoVentaCliente => ({
  cliente_id: '1',
  estado: 'entregado',
  canal: 'app',
  total: 0,
  fecha: '2026-10-01',
  created_at: '2026-10-01T15:00:00Z',
  ...p,
})

describe('calcularVentaCliente (venta de la mig 241: entregado, canal <> cambio)', () => {
  it('sin pedidos: todo en cero', () => {
    expect(calcularVentaCliente([])).toEqual({
      totalComprado: 0, cantidadCompras: 0, pendienteEntrega: 0, pedidosPendientesEntrega: 0,
    })
  })

  it('un pedido entregado es venta', () => {
    const r = calcularVentaCliente([pedido({ id: 'a', total: 1000 })])
    expect(r.totalComprado).toBe(1000)
    expect(r.cantidadCompras).toBe(1)
    expect(r.pendienteEntrega).toBe(0)
  })

  it('un pedido tomado y no entregado NO es venta: va a lo pendiente de entrega', () => {
    const r = calcularVentaCliente([
      pedido({ id: 'a', total: 1000 }),
      pedido({ id: 'b', total: 500, estado: 'pendiente' }),
      pedido({ id: 'c', total: 300, estado: 'asignado' }),
    ])
    expect(r.totalComprado).toBe(1000)
    expect(r.cantidadCompras).toBe(1)
    expect(r.pendienteEntrega).toBe(800)
    expect(r.pedidosPendientesEntrega).toBe(2)
  })

  it('un pedido cancelado no es venta ni pendiente', () => {
    const r = calcularVentaCliente([
      pedido({ id: 'a', total: 1000 }),
      pedido({ id: 'b', total: 700, estado: 'cancelado' }),
    ])
    expect(r.totalComprado).toBe(1000)
    expect(r.cantidadCompras).toBe(1)
    expect(r.pendienteEntrega).toBe(0)
    expect(r.pedidosPendientesEntrega).toBe(0)
  })

  it("un pedido de canal 'cambio' entregado no cuenta como compra", () => {
    const r = calcularVentaCliente([
      pedido({ id: 'a', total: 1000 }),
      pedido({ id: 'b', total: 0, canal: 'cambio' }),
    ])
    expect(r.totalComprado).toBe(1000)
    expect(r.cantidadCompras).toBe(1)
  })

  it('un pedido cargado de noche (created_at ya es el día siguiente en UTC) cuenta igual: la venta es por fecha, no por created_at', () => {
    // 22:30 en Argentina del 30/09 = 01:30 UTC del 01/10.
    const r = calcularVentaCliente([
      pedido({ id: 'a', total: 400, fecha: '2026-09-30', created_at: '2026-10-01T01:30:00Z' }),
    ])
    expect(r.totalComprado).toBe(400)
    expect(r.cantidadCompras).toBe(1)
  })

  it('total null se toma como 0', () => {
    const r = calcularVentaCliente([pedido({ id: 'a', total: null })])
    expect(r.totalComprado).toBe(0)
    expect(r.cantidadCompras).toBe(1)
  })
})

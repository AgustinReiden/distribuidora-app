/**
 * "Nota de crédito (vencidos)" en el menú ⋮ del pedido (#833). Espejo del gate
 * de crear_nota_credito_venta (mig 276): admin o encargado, sólo sobre pedidos
 * entregados. Nunca es la acción visible de la tarjeta.
 */
import { describe, it, expect, vi } from 'vitest'
import { construirAccionesPedido, elegirAccionPrincipal } from './accionPrincipalPedido'
import type { PedidoDB } from '../types'

function pedido(estado: string): PedidoDB {
  return {
    id: '6510',
    cliente_id: '858',
    estado,
    estado_pago: 'pagado',
    monto_pagado: 31700,
    total: 31700,
    items: [{ id: '23807', pedido_id: '6510', producto_id: '10', cantidad: 1, precio_unitario: 11100 }],
  } as unknown as PedidoDB
}

const ids = (p: PedidoDB, ctx: Parameters<typeof construirAccionesPedido>[1], onNC = vi.fn()) =>
  construirAccionesPedido(p, ctx, { onNotaCreditoVenta: onNC }).map(a => a.id)

describe('acción nota_credito_venta', () => {
  it('admin y encargado la ven sobre un entregado', () => {
    expect(ids(pedido('entregado'), { isAdmin: true })).toContain('nota_credito_venta')
    expect(ids(pedido('entregado'), { isEncargado: true })).toContain('nota_credito_venta')
  })

  it('no aparece para preventista, transportista ni depósito', () => {
    expect(ids(pedido('entregado'), { isPreventista: true })).not.toContain('nota_credito_venta')
    expect(ids(pedido('entregado'), { isTransportista: true })).not.toContain('nota_credito_venta')
    expect(ids(pedido('entregado'), {})).not.toContain('nota_credito_venta')
  })

  it('no aparece si el pedido no está entregado', () => {
    for (const estado of ['pendiente', 'en_preparacion', 'asignado', 'cancelado']) {
      expect(ids(pedido(estado), { isAdmin: true })).not.toContain('nota_credito_venta')
    }
  })

  it('sin handler no se ofrece', () => {
    const acciones = construirAccionesPedido(pedido('entregado'), { isAdmin: true }, {})
    expect(acciones.map(a => a.id)).not.toContain('nota_credito_venta')
  })

  it('llama al handler con el pedido y no es la acción principal', () => {
    const onNC = vi.fn()
    const p = pedido('entregado')
    const acciones = construirAccionesPedido(p, { isAdmin: true }, { onNotaCreditoVenta: onNC })
    const nc = acciones.find(a => a.id === 'nota_credito_venta')!
    expect(nc.label).toBe('Nota de crédito (vencidos)')
    nc.onClick()
    expect(onNC).toHaveBeenCalledWith(p)
    expect(elegirAccionPrincipal('entregado', acciones)?.id).not.toBe('nota_credito_venta')
  })
})

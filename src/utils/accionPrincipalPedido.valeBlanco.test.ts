/**
 * Las acciones de un vale blanco (VB: consumo interno, nace entregado y
 * saldado). Un VB no admite pagos, no se edita ni cambia de cliente (se cancela
 * y se recarga), no se revierte la entrega, no lleva nota de crédito, y sólo el
 * admin lo cancela —aunque esté entregado—.
 */
import { describe, it, expect, vi } from 'vitest'
import {
  construirAccionesPedido,
  elegirAccionPrincipal,
  esValeBlanco,
  type ContextoAccionesPedido,
  type HandlersAccionesPedido,
} from './accionPrincipalPedido'
import type { PedidoDB } from '../types'

const USUARIO = 'u-1'

function handlers() {
  return {
    onHistorial: vi.fn(),
    onEditar: vi.fn(),
    onEditarNotas: vi.fn(),
    onPreparar: vi.fn(),
    onVolverAPendiente: vi.fn(),
    onEntregado: vi.fn(),
    onEntregadoConSalvedad: vi.fn(),
    onRevertir: vi.fn(),
    onCancelarPedido: vi.fn(),
    onRegistrarPago: vi.fn(),
    onImprimirComanda: vi.fn(),
    onNotaCreditoVenta: vi.fn(),
  } satisfies HandlersAccionesPedido
}

function vb(over: Partial<PedidoDB> = {}): PedidoDB {
  return {
    id: '900',
    cliente_id: '440',
    estado: 'entregado',
    estado_pago: 'pagado',
    tipo_factura: 'VB',
    total: 12345.67,
    monto_pagado: 12345.67,
    usuario_id: USUARIO,
    transportista_id: null,
    created_at: '2026-10-08T13:00:00Z',
    items: [{ id: 'i1', producto_id: '1', cantidad: 2, precio_unitario: 100, subtotal: 200 }],
    ...over,
  } as unknown as PedidoDB
}

const PERFILES: Record<string, ContextoAccionesPedido> = {
  admin: { isAdmin: true, currentUserId: USUARIO },
  encargado: { isEncargado: true, currentUserId: USUARIO },
  preventista: { isPreventista: true, currentUserId: USUARIO },
  transportista: { isTransportista: true, currentUserId: USUARIO },
  deposito: { currentUserId: USUARIO },
}

const ids = (pedido: PedidoDB, perfil: ContextoAccionesPedido) =>
  construirAccionesPedido(pedido, perfil, handlers()).map(a => a.id)

describe('esValeBlanco', () => {
  it('sólo tipo_factura VB', () => {
    expect(esValeBlanco(vb())).toBe(true)
    expect(esValeBlanco(vb({ tipo_factura: 'ZZ' }))).toBe(false)
    expect(esValeBlanco(vb({ tipo_factura: 'FC' }))).toBe(false)
    expect(esValeBlanco(vb({ tipo_factura: undefined }))).toBe(false)
    expect(esValeBlanco(null)).toBe(false)
  })
})

describe('construirAccionesPedido — vale blanco entregado', () => {
  it('admin: historial, comanda, observaciones y cancelar (aunque esté entregado)', () => {
    expect(ids(vb(), PERFILES.admin)).toEqual(['historial', 'imprimir_comanda', 'editar_observaciones', 'cancelar'])
  })

  it('encargado: sin cancelar', () => {
    expect(ids(vb(), PERFILES.encargado)).toEqual(['historial', 'imprimir_comanda', 'editar_observaciones'])
  })

  it('preventista: historial y observaciones', () => {
    expect(ids(vb(), PERFILES.preventista)).toEqual(['historial', 'editar_observaciones'])
  })

  it('transportista y depósito: sólo historial', () => {
    expect(ids(vb(), PERFILES.transportista)).toEqual(['historial'])
    expect(ids(vb({ transportista_id: USUARIO } as Partial<PedidoDB>), PERFILES.transportista)).toEqual(['historial'])
    expect(ids(vb(), PERFILES.deposito)).toEqual(['historial'])
  })

  it.each(Object.keys(PERFILES))('%s: nunca pagos, editar ítems, revertir, NC, entregar ni salvedad', (perfil) => {
    const lista = ids(vb(), PERFILES[perfil])
    for (const prohibido of [
      'registrar_pago', 'ver_editar_pagos', 'ver_anular_pagos', 'editar', 'editar_pedido',
      'revertir_entrega', 'nota_credito_venta', 'entregado', 'entrega_con_salvedad',
      'preparar', 'volver_a_pendiente',
    ] as const) {
      expect(lista).not.toContain(prohibido)
    }
  })

  it('un ZZ entregado equivalente SÍ ofrece pagos, revertir y NC (el VB no es una resta accidental)', () => {
    const lista = ids(vb({ tipo_factura: 'ZZ' }), PERFILES.admin)
    expect(lista).toContain('ver_editar_pagos')
    expect(lista).toContain('revertir_entrega')
    expect(lista).toContain('nota_credito_venta')
    expect(lista).not.toContain('cancelar')
  })

  it('cancelar llama al handler con el pedido', () => {
    const h = handlers()
    const pedido = vb()
    const cancelar = construirAccionesPedido(pedido, PERFILES.admin, h).find(a => a.id === 'cancelar')
    cancelar?.onClick()
    expect(h.onCancelarPedido).toHaveBeenCalledWith(pedido)
  })
})

describe('construirAccionesPedido — vale blanco cancelado', () => {
  it('admin: sin cancelar ni observaciones, sin "Ver/Anular Pagos"', () => {
    expect(ids(vb({ estado: 'cancelado', total: 0, monto_pagado: 0 }), PERFILES.admin))
      .toEqual(['historial', 'imprimir_comanda'])
  })
})

describe('elegirAccionPrincipal — vale blanco', () => {
  it.each(Object.keys(PERFILES))('%s: ninguna acción principal (no hay "Registrar Pago")', (perfil) => {
    const acciones = construirAccionesPedido(vb(), PERFILES[perfil], handlers())
    expect(elegirAccionPrincipal('entregado', acciones)).toBeNull()
  })
})

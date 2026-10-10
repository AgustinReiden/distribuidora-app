/**
 * Un pedido `anulado` es una baja igual que uno `cancelado` (#1080): la base lo
 * trata así en todas las funciones (no se edita, no se entrega, no se cobra, no
 * se cancela de nuevo). El menú ⋮ tiene que ofrecer EXACTAMENTE lo mismo que
 * para un cancelado, con y sin pagos cargados, y la tarjeta no saca ninguna
 * acción afuera.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  construirAccionesPedido,
  elegirAccionPrincipal,
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

function pedido(estado: 'cancelado' | 'anulado', over: Partial<PedidoDB> = {}): PedidoDB {
  return {
    id: '4625',
    cliente_id: '10',
    usuario_id: USUARIO,
    // El chofer de la parada es el usuario: si el estado no lo frenara, el
    // transportista vería "Marcar Entregado".
    transportista_id: USUARIO,
    estado,
    estado_pago: 'pendiente',
    total: 0,
    monto_pagado: 0,
    fecha: '2026-09-17',
    // Creado hoy y dentro de la ventana del preventista: si el estado no lo
    // frenara, el preventista dueño vería "Editar Pedido".
    created_at: '2026-09-17T13:00:00Z',
    items: [{ id: '1', producto_id: '9', cantidad: 2, precio_unitario: 100 }],
    ...over,
  } as unknown as PedidoDB
}

const PERFILES: Record<string, ContextoAccionesPedido> = {
  admin: { isAdmin: true, currentUserId: USUARIO },
  encargado: { isEncargado: true, currentUserId: USUARIO },
  'admin + transportista': { isAdmin: true, isTransportista: true, currentUserId: USUARIO },
  preventista: { isPreventista: true, currentUserId: USUARIO },
  transportista: { isTransportista: true, currentUserId: USUARIO },
  deposito: { currentUserId: USUARIO },
}

const VARIANTES: Record<string, Partial<PedidoDB>> = {
  'sin pagos': {},
  'con pagos cargados': { monto_pagado: 5000, estado_pago: 'parcial' } as Partial<PedidoDB>,
  'vale blanco': { tipo_factura: 'VB', estado_pago: 'pagado' } as Partial<PedidoDB>,
}

const CASOS = Object.keys(PERFILES).flatMap(perfil =>
  Object.keys(VARIANTES).map(variante => ({ perfil, variante })),
)

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] })
  // 12:00 ARG del mismo día: dentro de la ventana de edición del preventista.
  vi.setSystemTime(new Date('2026-09-17T15:00:00Z'))
})

afterEach(() => {
  vi.useRealTimers()
})

describe('construirAccionesPedido — anulado = cancelado (#1080)', () => {
  it.each(CASOS)('$perfil, $variante: mismo menú que un cancelado', ({ perfil, variante }) => {
    const ctx = PERFILES[perfil]
    const over = VARIANTES[variante]
    const ids = (estado: 'cancelado' | 'anulado') =>
      construirAccionesPedido(pedido(estado, over), ctx, handlers()).map(a => `${a.id}:${a.label}`)

    expect(ids('anulado')).toEqual(ids('cancelado'))
  })

  it('un anulado no ofrece ninguna acción de pedido activo', () => {
    const activas = ['editar', 'editar_pedido', 'registrar_pago', 'ver_editar_pagos', 'entregado', 'entrega_con_salvedad', 'cancelar', 'preparar', 'volver_a_pendiente']
    for (const ctx of Object.values(PERFILES)) {
      for (const over of Object.values(VARIANTES)) {
        const ids = construirAccionesPedido(pedido('anulado', over), ctx, handlers()).map(a => a.id)
        expect(ids.filter(id => activas.includes(id))).toEqual([])
      }
    }
  })

  it('un anulado con plata cargada ofrece "Ver/Anular Pagos" al staff, como un cancelado', () => {
    const acciones = construirAccionesPedido(
      pedido('anulado', { monto_pagado: 5000 } as Partial<PedidoDB>),
      PERFILES.admin,
      handlers(),
    )
    expect(acciones.find(a => a.id === 'ver_anular_pagos')?.label).toBe('Ver/Anular Pagos')
  })

  it.each(Object.keys(PERFILES))('%s: la tarjeta no saca ninguna acción afuera', (perfil) => {
    const acciones = construirAccionesPedido(pedido('anulado'), PERFILES[perfil], handlers())
    expect(elegirAccionPrincipal('anulado', acciones)).toBeNull()
  })
})

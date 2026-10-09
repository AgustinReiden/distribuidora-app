/**
 * La acción visible de la tarjeta de pedido (#768, WP-43).
 *
 * Lo que importa: la acción de afuera es SIEMPRE un ítem que el menú ⋮ ya le
 * ofrece a ese usuario sobre ese pedido (mismo objeto, mismo handler), elegido
 * por la prioridad del dueño. Los perfiles son los de la matriz de
 * `PedidoActions.test.tsx`, con los mismos flags, el mismo usuario y la misma
 * hora; si esa matriz cambia, estos casos tienen que seguirla.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  construirAccionesPedido,
  elegirAccionPrincipal,
  type AccionItem,
  type ContextoAccionesPedido,
  type HandlersAccionesPedido,
} from './accionPrincipalPedido'
import type { PedidoDB, PedidoItemDB } from '../types'

/** El usuario logueado en todos los casos. */
const USUARIO = 'u-1'
/** Otro usuario cualquiera: dueño de la parada ajena. */
const OTRO = 'u-2'

/** 12:00 ARG del 17/09/2026 — antes del corte de 15:30 del preventista. */
const DENTRO_DE_VENTANA = new Date('2026-09-17T15:00:00Z')
/** 16:00 ARG del mismo día — después del corte. */
const FUERA_DE_VENTANA = new Date('2026-09-17T19:00:00Z')
/** 10:00 ARG del 17/09/2026. */
const CREADO_HOY = '2026-09-17T13:00:00Z'

const ESTADOS = ['pendiente', 'en_preparacion', 'asignado', 'entregado', 'cancelado'] as const
type EstadoProbado = (typeof ESTADOS)[number]

const ENTREGADO = 'Marcar Entregado'
const REGISTRAR_PAGO = 'Registrar Pago'
const PREPARAR = 'Marcar en Preparacion'
const EDITAR_PEDIDO = 'Editar Pedido'

interface Perfil extends ContextoAccionesPedido {
  ahora: Date
  transportistaDelPedido: string
}

const PERFILES = {
  admin: { isAdmin: true, ahora: DENTRO_DE_VENTANA, transportistaDelPedido: OTRO },
  encargado: { isEncargado: true, ahora: DENTRO_DE_VENTANA, transportistaDelPedido: OTRO },
  'preventista dueno en ventana': { isPreventista: true, ahora: DENTRO_DE_VENTANA, transportistaDelPedido: OTRO },
  'preventista dueno fuera de ventana': { isPreventista: true, ahora: FUERA_DE_VENTANA, transportistaDelPedido: OTRO },
  'transportista de la parada': { isTransportista: true, ahora: DENTRO_DE_VENTANA, transportistaDelPedido: USUARIO },
  'transportista ajeno': { isTransportista: true, ahora: DENTRO_DE_VENTANA, transportistaDelPedido: OTRO },
  deposito: { ahora: DENTRO_DE_VENTANA, transportistaDelPedido: OTRO },
} as const satisfies Record<string, Perfil>

type NombrePerfil = keyof typeof PERFILES

function crearHandlers() {
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
  } satisfies HandlersAccionesPedido
}

interface OpcionesPedido {
  estado: EstadoProbado
  transportistaDelPedido?: string
  montoPagado?: number
  estadoPago?: 'pendiente' | 'parcial' | 'pagado'
  conItems?: boolean
}

function crearPedido(o: OpcionesPedido): PedidoDB {
  const items = o.conItems === false
    ? []
    : ([{ id: '1', producto_id: '9', cantidad: 2, precio_unitario: 100 }] as unknown as PedidoItemDB[])
  return {
    id: '4625',
    cliente_id: '10',
    usuario_id: USUARIO,
    transportista_id: o.transportistaDelPedido ?? OTRO,
    estado: o.estado,
    estado_pago: o.estadoPago ?? 'pendiente',
    total: 21600,
    monto_pagado: o.montoPagado ?? 0,
    fecha: '2026-09-17',
    created_at: CREADO_HOY,
    items,
  } as unknown as PedidoDB
}

/** Arma el menú como lo arma `AccionesDropdown` y elige la acción visible. */
function elegir(
  perfil: Perfil,
  pedido: PedidoDB,
  handlers: HandlersAccionesPedido = crearHandlers(),
): { acciones: AccionItem[]; elegida: AccionItem | null } {
  vi.setSystemTime(perfil.ahora)
  const { ahora: _ahora, transportistaDelPedido: _t, ...flags } = perfil
  const acciones = construirAccionesPedido(pedido, { ...flags, currentUserId: USUARIO }, handlers)
  return { acciones, elegida: elegirAccionPrincipal(pedido.estado, acciones) }
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] })
})

afterEach(() => {
  vi.useRealTimers()
})

// =============================================================================
// LA MATRIZ: perfil x estado -> acción visible (o ninguna)
// =============================================================================

const ESPERADO: Record<NombrePerfil, Record<EstadoProbado, string | null>> = {
  admin: {
    pendiente: PREPARAR, en_preparacion: null, asignado: ENTREGADO, entregado: REGISTRAR_PAGO, cancelado: null,
  },
  encargado: {
    pendiente: PREPARAR, en_preparacion: null, asignado: ENTREGADO, entregado: REGISTRAR_PAGO, cancelado: null,
  },
  // Tiene "Editar Pedido" también en en_preparacion y asignado, pero la regla
  // sólo lo saca afuera en pendiente.
  'preventista dueno en ventana': {
    pendiente: EDITAR_PEDIDO, en_preparacion: null, asignado: null, entregado: null, cancelado: null,
  },
  'preventista dueno fuera de ventana': {
    pendiente: null, en_preparacion: null, asignado: null, entregado: null, cancelado: null,
  },
  'transportista de la parada': {
    pendiente: null, en_preparacion: null, asignado: ENTREGADO, entregado: null, cancelado: null,
  },
  'transportista ajeno': {
    pendiente: null, en_preparacion: null, asignado: null, entregado: null, cancelado: null,
  },
  deposito: {
    pendiente: null, en_preparacion: null, asignado: null, entregado: null, cancelado: null,
  },
}

const CASOS = (Object.keys(PERFILES) as NombrePerfil[]).flatMap(perfil =>
  ESTADOS.map(estado => ({ perfil, estado, esperado: ESPERADO[perfil][estado] })),
)

describe('elegirAccionPrincipal — perfil x estado', () => {
  it.each(CASOS)('$perfil sobre un pedido $estado: $esperado', ({ perfil, estado, esperado }) => {
    const p = PERFILES[perfil]
    const { acciones, elegida } = elegir(p, crearPedido({ estado, transportistaDelPedido: p.transportistaDelPedido }))
    expect(elegida?.label ?? null).toBe(esperado)
    // Nunca inventa: si hay acción visible, es el MISMO ítem que tiene el menú.
    if (elegida) expect(acciones).toContain(elegida)
  })
})

// =============================================================================
// LOS BORDES DE LA REGLA
// =============================================================================

describe('elegirAccionPrincipal — bordes', () => {
  it('un entregado ya pagado no tiene acción visible ("Ver/Editar Pagos" no es lo que espera)', () => {
    const { acciones, elegida } = elegir(PERFILES.admin, crearPedido({
      estado: 'entregado', estadoPago: 'pagado', montoPagado: 21600,
    }))
    expect(acciones.map(a => a.label)).toContain('Ver/Editar Pagos')
    expect(elegida).toBeNull()
  })

  it('un entregado con pago parcial sigue ofreciendo "Registrar Pago"', () => {
    const { elegida } = elegir(PERFILES.admin, crearPedido({
      estado: 'entregado', estadoPago: 'parcial', montoPagado: 10000,
    }))
    expect(elegida?.label).toBe(REGISTRAR_PAGO)
  })

  it('un cancelado con plata cargada no saca "Ver/Anular Pagos" afuera', () => {
    const { acciones, elegida } = elegir(PERFILES.admin, crearPedido({ estado: 'cancelado', montoPagado: 5000 }))
    expect(acciones.map(a => a.label)).toContain('Ver/Anular Pagos')
    expect(elegida).toBeNull()
  })

  it('un asignado sin ítems pierde "Entrega con Salvedad" pero conserva "Marcar Entregado" afuera', () => {
    const { elegida } = elegir(PERFILES.admin, crearPedido({ estado: 'asignado', conItems: false }))
    expect(elegida?.label).toBe(ENTREGADO)
  })

  it('el preventista que también reparte, sobre su propia parada asignada, entrega', () => {
    const perfil: Perfil = {
      isPreventista: true, isTransportista: true, ahora: DENTRO_DE_VENTANA, transportistaDelPedido: USUARIO,
    }
    const { elegida } = elegir(perfil, crearPedido({ estado: 'asignado', transportistaDelPedido: USUARIO }))
    expect(elegida?.label).toBe(ENTREGADO)
  })

  it('un preventista sobre un pedido de OTRO preventista, aunque sea temprano, no tiene acción visible', () => {
    vi.setSystemTime(DENTRO_DE_VENTANA)
    const pedido = { ...crearPedido({ estado: 'pendiente' }), usuario_id: OTRO } as PedidoDB
    const acciones = construirAccionesPedido(pedido, { isPreventista: true, currentUserId: USUARIO }, crearHandlers())
    expect(elegirAccionPrincipal(pedido.estado, acciones)).toBeNull()
  })

  it('sin handlers no hay menú, y sin menú no hay acción visible', () => {
    vi.setSystemTime(DENTRO_DE_VENTANA)
    const pedido = crearPedido({ estado: 'pendiente' })
    const acciones = construirAccionesPedido(pedido, { isAdmin: true, currentUserId: USUARIO }, {})
    expect(acciones).toEqual([])
    expect(elegirAccionPrincipal(pedido.estado, acciones)).toBeNull()
  })

  // 'en_camino' y 'preparado' ya no son del dominio de EstadoPedido (mig 297): siguen
  // sirviendo como valor desconocido que llega de la base o de un bundle viejo.
  it.each(['en_camino', 'preparado', '', null, undefined])('un estado fuera de la regla (%s) no tiene acción visible', estado => {
    vi.setSystemTime(DENTRO_DE_VENTANA)
    const acciones = construirAccionesPedido(
      crearPedido({ estado: 'pendiente' }), { isAdmin: true, currentUserId: USUARIO }, crearHandlers(),
    )
    expect(elegirAccionPrincipal(estado, acciones)).toBeNull()
  })
})

// =============================================================================
// EL ÍTEM ELEGIDO LLAMA AL MISMO HANDLER QUE EL MENÚ
// =============================================================================

describe('elegirAccionPrincipal — el ítem elegido llama a su handler con el pedido', () => {
  it.each([
    { perfil: 'admin', estado: 'pendiente', handler: 'onPreparar' },
    { perfil: 'admin', estado: 'asignado', handler: 'onEntregado' },
    { perfil: 'encargado', estado: 'entregado', handler: 'onRegistrarPago' },
    { perfil: 'preventista dueno en ventana', estado: 'pendiente', handler: 'onEditar' },
    { perfil: 'transportista de la parada', estado: 'asignado', handler: 'onEntregado' },
  ] as const)('$perfil sobre $estado: $handler', ({ perfil, estado, handler }) => {
    const handlers = crearHandlers()
    const p = PERFILES[perfil]
    const pedido = crearPedido({ estado, transportistaDelPedido: p.transportistaDelPedido })
    const { elegida } = elegir(p, pedido, handlers)

    elegida?.onClick()

    expect(handlers[handler]).toHaveBeenCalledTimes(1)
    expect(handlers[handler]).toHaveBeenCalledWith(pedido)
    for (const [nombre, fn] of Object.entries(handlers)) {
      if (nombre !== handler) expect(fn, `${nombre} no debería llamarse`).not.toHaveBeenCalled()
    }
  })
})

// =============================================================================
// EL ARMADO DEL MENÚ: ids estables
// =============================================================================

describe('construirAccionesPedido — ids', () => {
  it.each(CASOS)('$perfil sobre $estado: cada acción tiene un id propio', ({ perfil, estado }) => {
    const p = PERFILES[perfil]
    const { acciones } = elegir(p, crearPedido({ estado, transportistaDelPedido: p.transportistaDelPedido }))
    const ids = acciones.map(a => a.id)
    expect(new Set(ids).size).toBe(ids.length)
  })

  it('las tres etiquetas de pago tienen ids distintos y el mismo handler', () => {
    const handlers = crearHandlers()
    vi.setSystemTime(DENTRO_DE_VENTANA)
    const ctx = { isAdmin: true, currentUserId: USUARIO }
    const casos = [
      { pedido: crearPedido({ estado: 'pendiente' }), id: 'registrar_pago', label: 'Registrar Pago' },
      { pedido: crearPedido({ estado: 'entregado', estadoPago: 'pagado', montoPagado: 21600 }), id: 'ver_editar_pagos', label: 'Ver/Editar Pagos' },
      { pedido: crearPedido({ estado: 'cancelado', montoPagado: 5000 }), id: 'ver_anular_pagos', label: 'Ver/Anular Pagos' },
    ] as const
    for (const { pedido, id, label } of casos) {
      const pago = construirAccionesPedido(pedido, ctx, handlers).find(a => a.id === id)
      expect(pago?.label).toBe(label)
      pago?.onClick()
      expect(handlers.onRegistrarPago).toHaveBeenLastCalledWith(pedido)
    }
    expect(handlers.onRegistrarPago).toHaveBeenCalledTimes(3)
  })
})

/**
 * Pedidos de fixture para `PedidoCard` y compañía.
 *
 * Cada entrada es un estado concreto que la card sabe dibujar: estado × estado de
 * pago × transportista × deuda previa × FC/ZZ × GPS. Si el tipo `PedidoDB` cambia,
 * esto rompe en `npm run typecheck`, que es exactamente para lo que está incluido
 * `dev/gallery/**` en el tsconfig.
 */
import type { PedidoDB, PedidoItemDB, PerfilDB } from '../../../src/types'
import type { PedidoStatsSummary } from '../../../src/hooks/queries'
import { CLIENTES_FIXTURE, PRODUCTOS_FIXTURE } from './catalogo'
import { PERFILES_FIXTURE } from './auth'

/** Fechas relativas a hoy, para que las cards no envejezcan solas en la galería. */
function hace(dias: number): string {
  const d = new Date()
  d.setDate(d.getDate() - dias)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

function enDias(dias: number): string {
  return hace(-dias)
}

function selloHora(dias: number, hora: string): string {
  return `${hace(dias)}T${hora}`
}

const PREVENTISTA: PerfilDB = PERFILES_FIXTURE.preventista
const TRANSPORTISTA: PerfilDB = PERFILES_FIXTURE.transportista

function item(
  pedidoId: string,
  idx: number,
  producto: keyof typeof PRODUCTOS_FIXTURE,
  cantidad: number,
  extra: Partial<PedidoItemDB> = {},
): PedidoItemDB {
  const p = PRODUCTOS_FIXTURE[producto]
  return {
    id: `${pedidoId}-${idx}`,
    pedido_id: pedidoId,
    producto_id: p.id,
    producto: p,
    cantidad,
    precio_unitario: p.precio,
    subtotal: p.precio * cantidad,
    origen_precio: 'lista',
    ...extra,
  }
}

const PEDIDO_PENDIENTE: PedidoDB = {
  id: '18420',
  cliente_id: CLIENTES_FIXTURE.kiosco.id,
  cliente: CLIENTES_FIXTURE.kiosco,
  usuario_id: PREVENTISTA.id,
  usuario: PREVENTISTA,
  estado: 'pendiente',
  estado_pago: 'pendiente',
  total: 28_700,
  tipo_factura: 'ZZ',
  monto_pagado: 0,
  fecha: hace(0),
  created_at: selloHora(0, '09:14:00'),
  deuda_previa: 0,
  items: [
    item('18420', 1, 'manaosCola', 12),
    item('18420', 2, 'sodaSifon', 8),
  ],
}

const PEDIDO_EN_PREPARACION: PedidoDB = {
  id: '18421',
  cliente_id: CLIENTES_FIXTURE.despensa.id,
  cliente: CLIENTES_FIXTURE.despensa,
  usuario_id: PREVENTISTA.id,
  usuario: PREVENTISTA,
  estado: 'en_preparacion',
  estado_pago: 'parcial',
  total: 62_400,
  monto_pagado: 30_000,
  tipo_factura: 'ZZ',
  forma_pago: 'efectivo',
  fecha: hace(0),
  created_at: selloHora(0, '10:02:00'),
  fecha_entrega_programada: enDias(1),
  deuda_previa: 0,
  items: [
    item('18421', 1, 'yerba', 6),
    item('18421', 2, 'azucar', 12),
    item('18421', 3, 'fideos', 18),
  ],
}

const PEDIDO_ASIGNADO_CON_DEUDA: PedidoDB = {
  id: '18398',
  cliente_id: CLIENTES_FIXTURE.almacen.id,
  cliente: CLIENTES_FIXTURE.almacen,
  usuario_id: PREVENTISTA.id,
  usuario: PREVENTISTA,
  transportista_id: TRANSPORTISTA.id,
  transportista: TRANSPORTISTA,
  estado: 'asignado',
  estado_pago: 'pendiente',
  total: 95_180,
  monto_pagado: 0,
  tipo_factura: 'ZZ',
  fecha: hace(2),
  created_at: selloHora(2, '08:47:00'),
  fecha_entrega_programada: enDias(0),
  // Tres boletas viejas sin cobrar: dispara el aviso de deuda previa (mig 215).
  deuda_previa: 184_300,
  deuda_previa_detalle: [
    { id: '18102', fecha: hace(28), monto: 61_400 },
    { id: '18190', fecha: hace(19), monto: 58_900 },
    { id: '18277', fecha: hace(9), monto: 64_000 },
  ],
  gps_status: 'ok',
  gps_lat: -26.8569,
  gps_lng: -65.2219,
  gps_accuracy: 12,
  items: [
    item('18398', 1, 'aceite', 12),
    item('18398', 2, 'harina', 20),
    item('18398', 3, 'manaosNaranja', 10),
  ],
}

const PEDIDO_ENTREGADO_PAGADO_FC: PedidoDB = {
  id: '18355',
  cliente_id: CLIENTES_FIXTURE.autoservicio.id,
  cliente: CLIENTES_FIXTURE.autoservicio,
  usuario_id: PREVENTISTA.id,
  usuario: PREVENTISTA,
  transportista_id: TRANSPORTISTA.id,
  transportista: TRANSPORTISTA,
  estado: 'entregado',
  estado_pago: 'pagado',
  total: 412_600,
  monto_pagado: 412_600,
  tipo_factura: 'FC',
  total_neto: 341_000,
  total_iva: 71_600,
  forma_pago: 'transferencia',
  fecha: hace(5),
  created_at: selloHora(5, '07:58:00'),
  fecha_entrega: hace(4),
  pagos: [
    { forma_pago: 'transferencia', monto: 300_000 },
    { forma_pago: 'efectivo', monto: 112_600 },
  ],
  gps_status: 'ok',
  gps_lat: -26.8151,
  gps_lng: -65.3186,
  deuda_previa: 0,
  items: [
    item('18355', 1, 'manaosCola', 40),
    item('18355', 2, 'manaosNaranja', 32),
    item('18355', 3, 'aguaMineral', 24),
    item('18355', 4, 'yerba', 18),
    item('18355', 5, 'aceite', 24),
    item('18355', 6, 'fideos', 60),
    item('18355', 7, 'azucar', 40),
    item('18355', 8, 'vinagre', 12),
    item('18355', 9, 'harina', 50, {
      es_bonificacion: true,
      precio_unitario: 0,
      subtotal: 0,
      descripcion_regalo: 'Regalo por volumen · 1 bolsón cada 10',
      origen_precio: 'bonificacion',
    }),
  ],
}

const PEDIDO_ENTREGADO_CON_SALVEDAD: PedidoDB = {
  id: '18371',
  cliente_id: CLIENTES_FIXTURE.almacen.id,
  cliente: CLIENTES_FIXTURE.almacen,
  usuario_id: PREVENTISTA.id,
  usuario: PREVENTISTA,
  transportista_id: TRANSPORTISTA.id,
  transportista: TRANSPORTISTA,
  estado: 'entregado',
  estado_pago: 'parcial',
  total: 46_200,
  monto_pagado: 30_000,
  tipo_factura: 'ZZ',
  forma_pago: 'efectivo',
  fecha: hace(3),
  created_at: selloHora(3, '11:31:00'),
  fecha_entrega: hace(2),
  notas: 'Dejar en el depósito del fondo. Preguntar por Ramón antes de descargar.',
  deuda_previa: 0,
  items: [
    item('18371', 1, 'sodaSifon', 10),
    item('18371', 2, 'aguaMineral', 8),
  ],
  salvedades: [
    {
      id: 'sv-1',
      motivo: 'producto_danado',
      cantidad_afectada: 2,
      monto_afectado: 1_960,
      estado_resolucion: 'pendiente',
      producto_id: PRODUCTOS_FIXTURE.sodaSifon.id,
    },
  ],
}

const PEDIDO_CANCELADO: PedidoDB = {
  id: '18312',
  cliente_id: CLIENTES_FIXTURE.despensa.id,
  cliente: CLIENTES_FIXTURE.despensa,
  usuario_id: PREVENTISTA.id,
  usuario: PREVENTISTA,
  estado: 'cancelado',
  // Sin `estado_pago`: así llegan los cancelados viejos y la card no tiene que
  // mostrar chip de pago.
  total: 0,
  monto_pagado: 0,
  tipo_factura: 'ZZ',
  fecha: hace(7),
  created_at: selloHora(7, '16:20:00'),
  motivo_cancelacion: 'CERRADO — el local no abrió en las dos barridas del día.',
  deuda_previa: 0,
  items: [item('18312', 1, 'fideos', 12)],
}

const PEDIDO_SIN_GPS: PedidoDB = {
  id: '18433',
  cliente_id: CLIENTES_FIXTURE.kiosco.id,
  cliente: CLIENTES_FIXTURE.kiosco,
  usuario_id: PREVENTISTA.id,
  usuario: PREVENTISTA,
  estado: 'pendiente',
  estado_pago: 'pendiente',
  total: 14_500,
  monto_pagado: 0,
  tipo_factura: 'ZZ',
  fecha: hace(0),
  created_at: selloHora(0, '12:44:00'),
  gps_status: 'denied',
  deuda_previa: 0,
  items: [item('18433', 1, 'manaosCola', 10)],
}

const PEDIDO_GPS_LEJOS: PedidoDB = {
  id: '18434',
  cliente_id: CLIENTES_FIXTURE.autoservicio.id,
  cliente: CLIENTES_FIXTURE.autoservicio,
  usuario_id: PREVENTISTA.id,
  usuario: PREVENTISTA,
  estado: 'pendiente',
  estado_pago: 'pendiente',
  total: 88_300,
  monto_pagado: 0,
  tipo_factura: 'FC',
  fecha: hace(0),
  created_at: selloHora(0, '13:05:00'),
  // Check-in a ~2 km de la dirección cargada: semáforo en rojo.
  gps_status: 'ok',
  gps_lat: -26.8330,
  gps_lng: -65.3050,
  gps_accuracy: 18,
  deuda_previa: 0,
  items: [
    item('18434', 1, 'aguaMineral', 30),
    item('18434', 2, 'manaosNaranja', 24),
  ],
}

export interface EjemploPedido {
  etiqueta: string
  pedido: PedidoDB
}

export const PEDIDOS_FIXTURE: EjemploPedido[] = [
  { etiqueta: 'pendiente · pago pendiente · sin transportista', pedido: PEDIDO_PENDIENTE },
  { etiqueta: 'en preparación · pago parcial · entrega programada', pedido: PEDIDO_EN_PREPARACION },
  { etiqueta: 'asignado · con transportista · con deuda previa · GPS ok', pedido: PEDIDO_ASIGNADO_CON_DEUDA },
  { etiqueta: 'entregado · pagado (combinado) · FC · 9 ítems con regalo', pedido: PEDIDO_ENTREGADO_PAGADO_FC },
  { etiqueta: 'entregado con salvedad · pago parcial · con notas', pedido: PEDIDO_ENTREGADO_CON_SALVEDAD },
  { etiqueta: 'cancelado · sin estado de pago · con motivo', pedido: PEDIDO_CANCELADO },
  { etiqueta: 'pendiente · GPS denegado', pedido: PEDIDO_SIN_GPS },
  { etiqueta: 'pendiente · GPS lejos de la dirección · FC', pedido: PEDIDO_GPS_LEJOS },
]

// =============================================================================
// PedidoStats
// =============================================================================

export const STATS_TIPICO: PedidoStatsSummary = {
  pendientes: { count: 37, monto: 1_284_500 },
  enPreparacion: { count: 12, monto: 486_200 },
  enCamino: { count: 28, monto: 1_902_700 },
  entregados: { count: 164, monto: 9_431_800 },
  impagos: { count: 41, monto: 2_117_300 },
  total: { count: 241, monto: 13_105_200 },
  aproximado: false,
}

export const STATS_EN_CERO: PedidoStatsSummary = {
  pendientes: { count: 0, monto: 0 },
  enPreparacion: { count: 0, monto: 0 },
  enCamino: { count: 0, monto: 0 },
  entregados: { count: 0, monto: 0 },
  impagos: { count: 0, monto: 0 },
  total: { count: 0, monto: 0 },
  aproximado: false,
}

export const STATS_APROXIMADO: PedidoStatsSummary = {
  ...STATS_TIPICO,
  total: { count: 20_000, monto: 118_402_900 },
  aproximado: true,
}

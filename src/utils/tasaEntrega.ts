/**
 * Tasa de entrega del Dashboard (#1197).
 *
 * Un rechazo total no queda en ningún estado "abierto": se registra cancelando
 * el pedido con un motivo tipificado (migs 143/175). Si la tasa mira sólo
 * pendiente + asignado + entregado, un mes cerrado da siempre 100% aunque haya
 * habido rechazos. Por eso el denominador suma los rechazados:
 *
 *   entregados / (entregados + rechazados + pendientes + asignados)
 *
 * "Rechazado" es la misma clasificación que el panel "Mis entregas" (mig 179):
 * un cancelado cuyo motivo NO es administrativo. Un cancelado sin motivo cuenta
 * como rechazo, igual que en el `CASE` de la 179. Los canjes (canal 'cambio')
 * no son venta y no cuentan (mig 241). `anulado` tampoco: no es un rechazo del
 * cliente sino una baja de oficina.
 */
import { MOTIVOS_ADMINISTRATIVOS } from '../constants/desenlacePedido'
import type { PedidosPorEstado } from '../types'

const ADMINISTRATIVOS: ReadonlySet<string> = new Set(MOTIVOS_ADMINISTRATIVOS)

export interface PedidoCanceladoRow {
  estado: string
  canal?: string | null
  motivo_cancelacion_tipo?: string | null
}

/** ¿El pedido es un rechazo total del cliente (cancelado por motivo no administrativo)? */
export function esRechazoTotal(p: PedidoCanceladoRow): boolean {
  if (p.estado !== 'cancelado') return false
  if (p.canal === 'cambio') return false
  return !p.motivo_cancelacion_tipo || !ADMINISTRATIVOS.has(p.motivo_cancelacion_tipo)
}

export function contarRechazosTotales(rows: PedidoCanceladoRow[]): number {
  return rows.filter(esRechazoTotal).length
}

/** Porcentaje 0–100. Sin pedidos en el período da 0. */
export function calcularTasaEntrega(porEstado: PedidosPorEstado, rechazados: number): number {
  const denominador = porEstado.entregado + rechazados + porEstado.pendiente + porEstado.asignado
  return denominador > 0 ? (porEstado.entregado / denominador) * 100 : 0
}

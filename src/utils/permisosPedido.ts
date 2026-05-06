/**
 * Permisos de edicion de pedidos por preventista.
 *
 * Regla: el preventista creador puede editar items, cantidades y fecha de entrega
 * de su pedido propio mientras siga siendo el mismo dia (zona ARG) y la hora
 * actual ARG sea estrictamente menor a HORA_CORTE_PREVENTISTA.
 * Despues del corte, solo admin/encargado pueden editar.
 *
 * No permite editar precios — eso se hace cumplir tambien en el RPC SQL.
 */

import { fechaLocalISO } from './formatters'
import type { EstadoPedido } from '@/types'

export const HORA_CORTE_PREVENTISTA = 17

interface PedidoLike {
  usuario_id?: string | null
  created_at?: string | null | undefined
  estado?: EstadoPedido | string | null
}

function horaArg(date: Date): number {
  const hh = new Intl.DateTimeFormat('en-GB', {
    hour: '2-digit',
    hour12: false,
    timeZone: 'America/Argentina/Buenos_Aires',
  }).format(date)
  return parseInt(hh, 10)
}

export function preventistaPuedeEditar(
  pedido: PedidoLike,
  currentUserId: string | undefined,
  now: Date = new Date(),
): boolean {
  if (!currentUserId) return false
  if (!pedido.usuario_id || pedido.usuario_id !== currentUserId) return false
  if (pedido.estado === 'entregado' || pedido.estado === 'cancelado') return false
  if (!pedido.created_at) return false

  const hoyArg = fechaLocalISO(now)
  const creadoArg = fechaLocalISO(new Date(pedido.created_at))
  if (creadoArg !== hoyArg) return false

  return horaArg(now) < HORA_CORTE_PREVENTISTA
}

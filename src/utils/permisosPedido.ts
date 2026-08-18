/**
 * Permisos de edicion de pedidos por preventista.
 *
 * Regla: el preventista creador puede editar items, cantidades y fecha de entrega
 * de su pedido propio mientras siga siendo el mismo dia (zona ARG) y la hora
 * actual ARG sea estrictamente menor a 15:30.
 * Despues del corte, solo admin/encargado pueden editar.
 *
 * No permite editar precios — eso se hace cumplir tambien en el RPC SQL.
 *
 * `asignado` se permite a proposito (ver el test): que haya transportista no
 * implica que la ruta haya salido. Lo que NO se puede es editar un pedido que ya
 * esta en un recorrido en curso —los fardos estan arriba del camion y editarlo
 * deja stock fantasma, paso 86 veces— y eso lo rechaza `actualizar_pedido_items`
 * (mig 181), que es el unico lugar donde se sabe si hay recorrido. Desde aca no
 * se puede distinguir sin pedir ese dato, y un proxy por `estado` bloquearia de
 * mas.
 */

import { fechaLocalISO } from './formatters'
import type { EstadoPedido } from '@/types'

export const HORA_CORTE_PREVENTISTA = 15
export const MINUTO_CORTE_PREVENTISTA = 30

interface PedidoLike {
  usuario_id?: string | null
  created_at?: string | null | undefined
  estado?: EstadoPedido | string | null
}

function minutosArg(date: Date): number {
  const hhmm = new Intl.DateTimeFormat('en-GB', {
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
    timeZone: 'America/Argentina/Buenos_Aires',
  }).format(date)
  const [h, m] = hhmm.split(':').map(Number)
  return h * 60 + m
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

  return minutosArg(now) < HORA_CORTE_PREVENTISTA * 60 + MINUTO_CORTE_PREVENTISTA
}

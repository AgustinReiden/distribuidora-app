/**
 * #1204 · Todo pedido entregado queda con su chofer.
 *
 * El server (trigger `trg_pedidos_entrega_con_chofer`, mig 385) rechaza marcar
 * entregado un pedido que no es vale blanco si no tiene chofer ni está marcado
 * como retiro en depósito. Esto es lo que el front pregunta antes, para no
 * llegar al error: si el pedido no tiene chofer, quién lo repartió.
 *
 * El VB no lleva chofer: es mercadería que se retira del depósito.
 */
import type { PedidoDB } from '../types'

export type EleccionChofer =
  | { tipo: 'chofer'; transportistaId: string }
  | { tipo: 'retiro' }

export function necesitaElegirChofer(
  pedido: Pick<PedidoDB, 'transportista_id' | 'tipo_factura'>
): boolean {
  return !pedido.transportista_id && pedido.tipo_factura !== 'VB'
}

/** Lo que la elección le suma al cambio de estado a 'entregado'. */
export function datosDeEntrega(
  eleccion: EleccionChofer | null | undefined
): { transportistaId?: string; retiroDeposito?: boolean } {
  if (!eleccion) return {}
  return eleccion.tipo === 'retiro'
    ? { retiroDeposito: true }
    : { transportistaId: eleccion.transportistaId }
}

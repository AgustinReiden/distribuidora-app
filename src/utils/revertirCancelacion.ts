/**
 * Revertir la cancelación de un pedido (mig 559_revertir_cancelacion, decisión del
 * dueño del 26/11/2026). La hace sólo un admin con `revertir_cancelacion_pedido`,
 * que valida todo de nuevo: esto decide si el menú la ofrece y qué dicen la
 * confirmación y el aviso.
 */
import type { PedidoDB } from '../types'
import { formatPrecio } from './formatters'

type PedidoParaRevertir = Pick<PedidoDB, 'estado' | 'tipo_factura' | 'canal' | 'fecha_entrega'> & {
  motivo_cancelacion_tipo?: string | null
}

/**
 * ¿El menú ofrece "Revertir cancelación"? Lo mismo que el server rechaza sin mirar
 * el stock ni los cobros: la cancelación del cambio de cliente (ya existe el pedido
 * nuevo), la comanda de un canje y un pedido con fecha de entrega (tocaría la
 * rendición). Un vale blanco entregado tiene fecha de entrega, así que tampoco; uno
 * que no estaba entregado sí se revierte, como en el server (sólo el VB entregado
 * no se revierte).
 */
export function puedeRevertirCancelacion(pedido: PedidoParaRevertir, isAdmin: boolean | undefined): boolean {
  return Boolean(isAdmin)
    && pedido.estado === 'cancelado'
    && pedido.motivo_cancelacion_tipo !== 'cambio_de_cliente'
    && pedido.canal !== 'cambio'
    && !pedido.fecha_entrega
}

/** Lo que dice la confirmación antes de revertir. */
export function mensajeConfirmarRevertirCancelacion(pedido: Pick<PedidoDB, 'id'>): string {
  return `El pedido #${pedido.id} vuelve a "Pendiente", sin chofer ni ruta, con sus líneas y precios. ` +
    'Vuelve a descontar su stock: si hoy no alcanza algún producto, no se revierte. ' +
    'Lo cobrado que siga a favor del cliente vuelve a la boleta; lo que la cancelación ya aplicó a ' +
    'otras boletas se queda ahí y este pedido queda debiendo esa parte. ' +
    'Un regalo de una promo que ya no tiene cupo vuelve sin ese regalo. ' +
    'Si se canceló por falta de stock, su merma se anula.'
}

/** La respuesta de `revertir_cancelacion_pedido` cuando sale bien. */
export interface ResultadoRevertirCancelacion {
  success: true
  pedido_id?: number
  total?: number
  cobro_vuelto?: number
  pagos_vueltos?: number
  regalos_quitados?: Array<{ promocion_id: number; promocion?: string | null; motivo?: string }>
  /** Las promos que con la reversión llegaron a su cupo y se apagaron. */
  promos_apagadas?: Array<{ promocion_id: number; promocion?: string | null }>
  mermas_anuladas?: number
  sin_foto?: boolean
  mensaje?: string
}

/** El aviso después de revertir, con lo que pasó con la plata, los regalos y las mermas. */
export function mensajeCancelacionRevertida(r: ResultadoRevertirCancelacion): string {
  const partes = ['Cancelación revertida: el pedido volvió a pendiente y descontó su stock']
  const vuelto = Number(r.cobro_vuelto ?? 0)
  if (vuelto > 0) {
    partes.push(`volvió ${formatPrecio(vuelto)} de lo cobrado`)
  } else if (r.sin_foto) {
    partes.push('la cancelación es anterior a la foto: no volvió ningún cobro')
  }
  const regalos = r.regalos_quitados ?? []
  if (regalos.length > 0) {
    const nombres = regalos.map(q => q.promocion || `promo #${q.promocion_id}`).join(', ')
    partes.push(`volvió sin el regalo de ${nombres}`)
  }
  const apagadas = r.promos_apagadas ?? []
  if (apagadas.length > 0) {
    const nombres = apagadas.map(q => q.promocion || `promo #${q.promocion_id}`).join(', ')
    partes.push(`${apagadas.length === 1 ? 'se apagó la promo' : 'se apagaron las promos'} ${nombres}: llegó a su cupo`)
  }
  const mermas = Number(r.mermas_anuladas ?? 0)
  if (mermas > 0) {
    partes.push(`${mermas === 1 ? 'se anuló 1 merma' : `se anularon ${mermas} mermas`}`)
  }
  return partes.join('; ')
}

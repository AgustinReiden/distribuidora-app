import { formatDateTime } from './formatters'

/**
 * Quién marcó el pedido como entregado y cuándo (`pedidos.entregado_por` y
 * `entregado_at`, escritos por un trigger del servidor).
 *
 * `entregado_at` es el instante en que se marcó, NO `fecha_entrega` (la fecha
 * declarada de la entrega, anclada a mediodía y elegible hacia atrás): un pedido
 * entregado el 10/11 puede haberse marcado el 12/11.
 */
export interface EntregaMarcada {
  /** Nombre de quien lo marcó; null si no hay perfil (no se inventa un "Sistema"). */
  quien: string | null
  /** Fecha y hora completas, en hora de Argentina. */
  cuando: string
  /** Versión corta para la tarjeta: "marcó Juan, 12/11 09:14" o "marcado el 12/11 09:14". */
  texto: string
}

interface PedidoConEntrega {
  estado: string
  entregado_at?: string | null
  entregado_por_perfil?: { nombre?: string | null } | null
}

/** "12/11 09:14": día/mes y hora, sin año, siempre en hora de Argentina. */
function diaMesHora(iso: string): string {
  const fecha = new Date(iso)
  if (isNaN(fecha.getTime())) return ''
  const partes = new Intl.DateTimeFormat('es-AR', {
    timeZone: 'America/Argentina/Buenos_Aires',
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(fecha)
  const valor = (tipo: string) => partes.find(p => p.type === tipo)?.value ?? ''
  return `${valor('day')}/${valor('month')} ${valor('hour')}:${valor('minute')}`
}

export function entregaMarcada(pedido: PedidoConEntrega): EntregaMarcada | null {
  if (pedido.estado !== 'entregado' || !pedido.entregado_at) return null

  const cuando = formatDateTime(pedido.entregado_at)
  const corto = diaMesHora(pedido.entregado_at)
  if (!cuando || !corto) return null

  const nombre = pedido.entregado_por_perfil?.nombre?.trim()
  const quien = nombre || null

  return {
    quien,
    cuando,
    texto: quien ? `marcó ${quien}, ${corto}` : `marcado el ${corto}`,
  }
}

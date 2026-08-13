/**
 * Desenlace de un pedido para el panel "Mis entregas" (mig 179).
 *
 * Es una dimensión distinta de `pedidos.estado`: responde "¿el cliente
 * terminó recibiendo la mercadería?", que es lo que le importa al preventista.
 * Un `cancelado` puede ser un rechazo del cliente o la corrección de un error
 * de carga, y mezclarlos arruina el número.
 *
 * La clasificación la hace el SQL, no el front — acá sólo viven las etiquetas.
 * Las listas de motivos están para que un test pueda afirmar que cubren el
 * CHECK de la mig 175 entero: si mañana se agrega un motivo y nadie lo
 * clasifica, tiene que romper en CI, no aparecer callado en la columna
 * equivocada.
 */
import { AlertTriangle, Check, Clock, PackageX, Wrench, type LucideIcon } from 'lucide-react'
import {
  MOTIVOS_NO_ENTREGA,
  MOTIVOS_CANCELACION_ADMIN,
  MOTIVOS_CANCELACION_SISTEMA,
} from './motivosNoEntrega'

export type Desenlace =
  | 'entregado'
  | 'entregado_con_salvedad'
  | 'rechazado'
  | 'administrativo'
  | 'pendiente'

export const LABEL_DESENLACE: Record<Desenlace, string> = {
  entregado: 'Entregado',
  entregado_con_salvedad: 'Entregado con salvedad',
  rechazado: 'No entregado',
  administrativo: 'Corregido en oficina',
  pendiente: 'Sin resolver',
}

export interface EstiloDesenlace {
  /** Clases de la píldora. */
  badge: string
  /** Color del punto/contador en el encabezado del día. */
  punto: string
  icon: LucideIcon
}

export const ESTILO_DESENLACE: Record<Desenlace, EstiloDesenlace> = {
  entregado: {
    badge: 'bg-emerald-100 text-emerald-800 dark:bg-emerald-900/40 dark:text-emerald-200',
    punto: 'text-emerald-600 dark:text-emerald-400',
    icon: Check,
  },
  entregado_con_salvedad: {
    badge: 'bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-200',
    punto: 'text-amber-600 dark:text-amber-400',
    icon: AlertTriangle,
  },
  rechazado: {
    badge: 'bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-200',
    punto: 'text-red-600 dark:text-red-400',
    icon: PackageX,
  },
  administrativo: {
    badge: 'bg-gray-100 text-gray-600 dark:bg-gray-700 dark:text-gray-300',
    punto: 'text-gray-500 dark:text-gray-400',
    icon: Wrench,
  },
  pendiente: {
    badge: 'bg-sky-100 text-sky-800 dark:bg-sky-900/40 dark:text-sky-200',
    punto: 'text-sky-600 dark:text-sky-400',
    icon: Clock,
  },
}

/**
 * Los motivos que NO son un rechazo: el pedido no debía existir o fue
 * reemplazado por otro. Espeja la lista negra del `CASE` de la mig 179.
 *
 * Ojo: `cliente_cancelo` NO está acá aunque viva en MOTIVOS_CANCELACION_ADMIN.
 * Que el cliente cancele es justo de lo que el preventista tiene que
 * enterarse, no una corrección administrativa.
 */
export const MOTIVOS_ADMINISTRATIVOS = [
  'error_de_carga',
  'prueba',
  'duplicado',
  'unifica_pedidos',
  'cambio_de_cliente',
] as const

/** Todos los valores del CHECK `pedidos_motivo_cancelacion_tipo_check` (mig 175). */
export const MOTIVOS_CANCELACION_TODOS: readonly string[] = [
  ...MOTIVOS_NO_ENTREGA.map(m => m.valor),
  ...MOTIVOS_CANCELACION_ADMIN.map(m => m.valor),
  ...MOTIVOS_CANCELACION_SISTEMA.map(m => m.valor),
]

/** Filtros de la barra superior del panel. */
export type FiltroDesenlace = 'todos' | 'entregados' | 'rechazados' | 'pendientes'

export const LABEL_FILTRO: Record<FiltroDesenlace, string> = {
  todos: 'Todos',
  entregados: 'Entregados',
  rechazados: 'No entregados',
  pendientes: 'Sin resolver',
}

/** Qué desenlaces entran en cada filtro. `administrativo` nunca es un filtro:
 *  se muestra plegado al pie del día. */
export function desenlacesDelFiltro(filtro: FiltroDesenlace): Desenlace[] | null {
  switch (filtro) {
    case 'entregados':
      return ['entregado', 'entregado_con_salvedad']
    case 'rechazados':
      return ['rechazado']
    case 'pendientes':
      return ['pendiente']
    default:
      return null
  }
}

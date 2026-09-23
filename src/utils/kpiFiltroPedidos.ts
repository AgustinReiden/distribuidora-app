/**
 * Los seis KPIs de /pedidos como filtros (#715, WP-24).
 *
 * Cada tile de `PedidoStats` se corresponde con UN valor de UNA dimensión de
 * los filtros de la lista:
 *
 *   pendientes     → estado: 'pendiente'
 *   enPreparacion  → estado: 'en_preparacion'
 *   enCamino       → estado: 'asignado'     (NO 'en_camino': el summary cuenta 'asignado')
 *   entregados     → estado: 'entregado'
 *   impagos        → estadoPago: 'impago'   (sentinela: ver construirFiltrosPedidos)
 *   total          → limpia estado Y estadoPago
 *
 * Las dos dimensiones son independientes: tocar un tile de estado deja el
 * `estadoPago` como estaba, y tocar "Impagos" deja el `estado` como estaba. Así
 * "Pendientes" + "Impagos" se combinan (pendientes que no están pagados) en vez
 * de que un tile le pise el filtro al otro.
 *
 * Puro a propósito: el componente sólo pinta y llama a `onFiltrosChange` con lo
 * que devuelve `togglearKpi`.
 */
import type { FiltrosPedidosState } from '../types'
import type { PedidoStatKey } from '../lib/permisos'

/**
 * Sentinela de `estadoPago` para "todo lo que no está pagado", NULL incluido.
 * Es exactamente el criterio del bucket `impagos` de `usePedidoStatsQuery`
 * (`estado_pago !== 'pagado'`), no un valor de la columna.
 */
export const ESTADO_PAGO_IMPAGO = 'impago'

/**
 * Lo único de los filtros que miran los tiles. `verCancelados` sólo lo mira
 * "Total" (ver `togglearKpi`).
 */
export type FiltrosKpi = Pick<FiltrosPedidosState, 'estado' | 'estadoPago' | 'verCancelados'>

/** Tile de estado → valor de `pedidos.estado` que cuenta ese bucket del summary. */
const ESTADO_DE_KPI: Partial<Record<PedidoStatKey, string>> = {
  pendientes: 'pendiente',
  enPreparacion: 'en_preparacion',
  enCamino: 'asignado',
  entregados: 'entregado',
}

/** Orden en que `kpiActivo` busca un tile de estado que coincida. */
const KPIS_DE_ESTADO: PedidoStatKey[] = ['pendientes', 'enPreparacion', 'enCamino', 'entregados']

/** El Partial que aplica el tile, sin mirar lo que ya está filtrado. */
export function filtroDeKpi(key: PedidoStatKey): Partial<FiltrosPedidosState> {
  if (key === 'total') return { estado: 'todos', estadoPago: 'todos' }
  if (key === 'impagos') return { estadoPago: ESTADO_PAGO_IMPAGO }
  return { estado: ESTADO_DE_KPI[key] }
}

/**
 * Si ESE tile está aplicado en los filtros actuales. Mira sólo su dimensión, así
 * que un tile de estado y "Impagos" pueden estar los dos activos a la vez.
 * "Total" nunca queda activo: no es un filtro, es el botón de limpiar.
 */
export function kpiEstaActivo(key: PedidoStatKey, filtros: FiltrosKpi): boolean {
  if (key === 'total') return false
  if (key === 'impagos') return filtros.estadoPago === ESTADO_PAGO_IMPAGO
  return filtros.estado === ESTADO_DE_KPI[key]
}

/**
 * EL tile que corresponde a los filtros actuales, o `null` si ninguno. Con un
 * tile de estado y "Impagos" aplicados a la vez gana el de estado. "Total"
 * nunca: sin filtro de estado ni de pago no hay tile activo.
 */
export function kpiActivo(filtros: FiltrosKpi): PedidoStatKey | null {
  const deEstado = KPIS_DE_ESTADO.find(key => kpiEstaActivo(key, filtros))
  if (deEstado) return deEstado
  if (kpiEstaActivo('impagos', filtros)) return 'impagos'
  return null
}

/**
 * Lo que hay que pasarle a `onFiltrosChange` al tocar un tile: si el tile ya
 * estaba activo lo deselecciona (su dimensión vuelve a 'todos'); si no, lo
 * aplica. En los dos casos la OTRA dimensión no se toca. "Total" siempre limpia
 * las dos.
 *
 * "Total" con estado 'cancelado' además prende `verCancelados`. El número que
 * muestra ese tile sale de `filtrosParaStats`, que con 'cancelado' cuenta los
 * cancelados; si el clic sólo limpiara el estado, la lista volvería a
 * excluirlos (construirFiltrosPedidos) y mostraría menos filas que el tile que
 * se acaba de tocar. Así la lista que queda es exactamente la que el tile
 * contaba, y el cambio se ve en el checkbox "Ver cancelados".
 */
export function togglearKpi(key: PedidoStatKey, filtros: FiltrosKpi): Partial<FiltrosPedidosState> {
  if (key === 'total') {
    const limpiar = filtroDeKpi('total')
    return filtros.estado === 'cancelado' ? { ...limpiar, verCancelados: true } : limpiar
  }
  if (!kpiEstaActivo(key, filtros)) return filtroDeKpi(key)
  if (key === 'impagos') return { estadoPago: 'todos' }
  return { estado: 'todos' }
}

/**
 * Si "Total" tiene algo que limpiar: un estado o un pago elegidos. Sin ninguno
 * de los dos, `togglearKpi('total')` devolvería los mismos 'todos' que ya hay y
 * el clic sólo resetearía la página; el componente no lo manda.
 */
export function hayFiltroQueLimpiar(filtros: FiltrosKpi): boolean {
  return filtros.estado !== 'todos' || filtros.estadoPago !== 'todos'
}

/**
 * Los filtros con los que se calcula el summary de los tiles.
 *
 * Es la lista SIN estado ni estadoPago: si el summary usara los mismos filtros
 * que la lista, al tocar "Pendientes" los otros cinco tiles caerían a 0 y ya no
 * se podría saltar de uno a otro. Una sola query para los seis (el summary
 * pagina hasta 20.000 filas: duplicarla por tile es caro).
 *
 * `verCancelados`: con estado 'cancelado' la lista NO excluye los cancelados
 * (ver construirFiltrosPedidos). Al borrarle el estado al summary hay que
 * conservar ese efecto a mano, o el total del tile dejaría afuera justo lo que
 * la lista está mostrando.
 */
export function filtrosParaStats<F extends Partial<FiltrosPedidosState>>(filtros: F): F {
  return {
    ...filtros,
    estado: 'todos',
    estadoPago: 'todos',
    verCancelados: filtros.estado === 'cancelado' ? true : filtros.verCancelados,
  }
}

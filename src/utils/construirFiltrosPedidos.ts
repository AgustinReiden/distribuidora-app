/**
 * Arma los filtros de la consulta de `pedidos`: UN solo lugar para las tres
 * consultas que tienen que ver el mismo universo (la lista paginada, las cards
 * de stats y el export "todo lo filtrado"). Antes cada una rearmaba los
 * filtros a mano y se desincronizaban: el export omitía `usuarioId` y
 * `fechaEntregaProgramada`, y excluía cancelados con `.neq('estado',
 * 'cancelado')` en vez del `.or(...)` que también cubre `estado IS NULL` — el
 * Excel "todo lo filtrado" salía con otro universo que la pantalla (#524).
 *
 * PURA a propósito: no pagina ni llama a la base, sólo encadena filtros sobre
 * el query builder que le pasan. Por eso `conSalvedad` queda afuera —
 * necesita un round-trip previo a `salvedades_items` para resolver qué ids
 * tienen salvedad, así que lo resuelve `aplicarFiltroConSalvedad` con esa
 * lista ya en mano.
 */
import type { FiltrosPedidosState } from '../types'
import { escapePostgrestFilter } from './sanitize'

/** Lo mínimo que necesita un builder de supabase-js para poder filtrarse acá. */
export interface QueryFiltrablePedidos {
  eq(column: string, value: unknown): this
  gte(column: string, value: unknown): this
  lte(column: string, value: unknown): this
  or(filters: string, options?: { referencedTable?: string }): this
  in(column: string, values: unknown[]): this
  not(column: string, operator: string, value: unknown): this
}

export function construirFiltrosPedidos<Q extends QueryFiltrablePedidos>(
  query: Q,
  filtros?: Partial<FiltrosPedidosState>,
  busqueda?: string,
): Q {
  let q = query

  if (filtros?.estado && filtros.estado !== 'todos') q = q.eq('estado', filtros.estado)
  if (filtros?.estadoPago && filtros.estadoPago !== 'todos') q = q.eq('estado_pago', filtros.estadoPago)
  if (filtros?.transportistaId && filtros.transportistaId !== 'todos') q = q.eq('transportista_id', filtros.transportistaId)
  if (filtros?.usuarioId && filtros.usuarioId !== 'todos') q = q.eq('usuario_id', filtros.usuarioId)
  if (filtros?.fechaDesde) q = q.gte('fecha', filtros.fechaDesde)
  if (filtros?.fechaHasta) q = q.lte('fecha', filtros.fechaHasta)
  if (!filtros?.verCancelados && filtros?.estado !== 'cancelado') {
    // Alineado con bot_ventas_periodo (mig029): excluye 'cancelado' y 'anulado',
    // incluye estado IS NULL. `.neq` solo excluiría 'cancelado' y descartaría NULL.
    q = q.or('estado.is.null,and(estado.neq.cancelado,estado.neq.anulado)')
  }
  if (filtros?.fechaEntregaProgramada) q = q.eq('fecha_entrega_programada', filtros.fechaEntregaProgramada)

  // Escapado ANTES de interpolar: sin esto una coma o un paréntesis en la
  // búsqueda ("Perez, Juan") rompe la sintaxis de `.or()` y PostgREST devuelve
  // 400 PGRST100 — la lista entera queda en error, no solo la búsqueda.
  const termino = escapePostgrestFilter(busqueda)
  if (termino) {
    q = q.or(
      `nombre_fantasia.ilike.%${termino}%,razon_social.ilike.%${termino}%,cuit.ilike.%${termino}%,direccion.ilike.%${termino}%`,
      { referencedTable: 'clientes' },
    )
  }

  return q
}

/**
 * Filtro "Con salvedad / Sin salvedad". `idsConSalvedad` viene resuelto de
 * afuera (ver `fetchPedidoIdsConSalvedad` en usePedidosQuery.ts): pedirlo acá
 * adentro rompería la pureza de este módulo, porque es un round-trip a
 * `salvedades_items`, no un filtro sobre la query de pedidos.
 *
 * Sentinela `-1`: ningún pedido real tiene ese id, así que "con salvedad" sin
 * ninguna fila conocida no trae nada y "sin salvedad" sin ninguna fila
 * conocida no excluye nada — sin esto `.in('id', [])` arma un `in.()` que
 * PostgREST rechaza.
 */
export function aplicarFiltroConSalvedad<Q extends QueryFiltrablePedidos>(
  query: Q,
  conSalvedad: FiltrosPedidosState['conSalvedad'] | undefined,
  idsConSalvedad: number[] | null,
): Q {
  if (!conSalvedad || conSalvedad === 'todos') return query

  const ids = idsConSalvedad ?? []
  if (conSalvedad === 'con_salvedad') {
    return query.in('id', ids.length > 0 ? ids : [-1])
  }
  const lista = ids.length > 0 ? ids.join(',') : '-1'
  return query.not('id', 'in', `(${lista})`)
}

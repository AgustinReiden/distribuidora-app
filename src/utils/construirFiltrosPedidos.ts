/**
 * Arma los filtros de la consulta de `pedidos`: UN solo lugar para las tres
 * consultas que tienen que ver el mismo universo (la lista paginada, las cards
 * de stats y el export "todo lo filtrado"). Antes cada una rearmaba los
 * filtros a mano y se desincronizaban: el export omitía `usuarioId` y
 * `fechaEntregaProgramada`, y excluía cancelados con `.neq('estado',
 * 'cancelado')` en vez del `.or(...)` que también cubre `estado IS NULL` — el
 * Excel "todo lo filtrado" salía con otro universo que la pantalla (#524).
 * Las cards pasan por este mismo armado, pero con los filtros sin estado ni
 * pago (`filtrosParaStats`, #715): cada card es a la vez un filtro de la lista.
 *
 * PURA a propósito: no pagina ni llama a la base, sólo encadena filtros sobre
 * el query builder que le pasan. Por eso `conSalvedad` queda afuera —
 * necesita un round-trip previo a `salvedades_items` para resolver qué ids
 * tienen salvedad, así que lo resuelve `aplicarFiltroConSalvedad` con esa
 * lista ya en mano.
 */
import type { FiltrosPedidosState } from '../types'
import { escapePostgrestFilter } from './postgrest'
import { ESTADO_PAGO_IMPAGO } from './kpiFiltroPedidos'

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
  if (filtros?.estadoPago === ESTADO_PAGO_IMPAGO) {
    // Sentinela del tile "Impagos" (#715): todo lo que no está pagado, NULL
    // incluido — el mismo criterio con el que `usePedidoStatsQuery` cuenta el
    // bucket (`estado_pago !== 'pagado'`). Un `.neq('estado_pago','pagado')`
    // pelado excluye NULL en PostgREST (NULL <> 'pagado' no es true) y el tile
    // diría 120 donde la lista muestra 87.
    //
    // Convive con el `.or()` de cancelados de más abajo: supabase-js agrega cada
    // `.or()` con `searchParams.append`, o sea como otro parámetro `or=(...)`, y
    // PostgREST combina con AND todos los filtros de primer nivel, repetidos
    // incluidos. No se pisan ni se funden en un solo OR.
    q = q.or('estado_pago.is.null,estado_pago.neq.pagado')
  } else if (filtros?.estadoPago && filtros.estadoPago !== 'todos') {
    q = q.eq('estado_pago', filtros.estadoPago)
  }
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

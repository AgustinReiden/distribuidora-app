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
 * el query builder que le pasan. `conSalvedad` va aparte, en
 * `aplicarFiltroConSalvedad`.
 */
import type { FiltrosPedidosState } from '../types'
import { escapePostgrestFilter } from './postgrest'
import { ESTADO_PAGO_CONSUMO_INTERNO, ESTADO_PAGO_IMPAGO } from './kpiFiltroPedidos'

/** Lo mínimo que necesita un builder de supabase-js para poder filtrarse acá. */
export interface QueryFiltrablePedidos {
  eq(column: string, value: unknown): this
  gte(column: string, value: unknown): this
  lte(column: string, value: unknown): this
  or(filters: string, options?: { referencedTable?: string }): this
  in(column: string, values: unknown[]): this
  not(column: string, operator: string, value: unknown): this
  neq(column: string, value: unknown): this
  is(column: string, value: null): this
}

export function construirFiltrosPedidos<Q extends QueryFiltrablePedidos>(
  query: Q,
  filtros?: Partial<FiltrosPedidosState>,
  busqueda?: string,
): Q {
  let q = query

  if (filtros?.estado && filtros.estado !== 'todos') q = q.eq('estado', filtros.estado)
  if (filtros?.estado === 'entregado'
    && filtros.estadoPago !== ESTADO_PAGO_CONSUMO_INTERNO
    && filtros.estadoPago !== 'pagado') {
    // "Entregado" = venta entregada: el tile "Entregados" de `usePedidoStatsQuery`
    // no cuenta los vales blancos (van en "Consumo interno"), y si la lista los
    // trajera el tile diría 40 donde la lista muestra 43. Con el pago en
    // "Consumo interno" sí se ven (entregado + VB es justo eso), y con "Pagado"
    // ya los saca la rama de abajo. `.or` con IS NULL: `neq` pelado descarta NULL.
    q = q.or('tipo_factura.is.null,tipo_factura.neq.VB')
  }
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
  } else if (filtros?.estadoPago === ESTADO_PAGO_CONSUMO_INTERNO) {
    // Vales blancos: saldados por naturaleza, sin pagos. No es un estado_pago.
    q = q.eq('tipo_factura', 'VB')
  } else if (filtros?.estadoPago === 'pagado') {
    // "Pagado" = plata cobrada: un VB tiene estado_pago 'pagado' sin un solo
    // pago, así que va aparte (opción "Consumo interno"). `.or` con IS NULL por
    // la misma razón que el sentinela de impagos: `neq` pelado descarta NULL.
    q = q.eq('estado_pago', 'pagado').or('tipo_factura.is.null,tipo_factura.neq.VB')
  } else if (filtros?.estadoPago && filtros.estadoPago !== 'todos') {
    q = q.eq('estado_pago', filtros.estadoPago)
  }
  if (filtros?.transportistaId && filtros.transportistaId !== 'todos') q = q.eq('transportista_id', filtros.transportistaId)
  if (filtros?.usuarioId && filtros.usuarioId !== 'todos') q = q.eq('usuario_id', filtros.usuarioId)
  if (filtros?.fechaDesde) q = q.gte('fecha', filtros.fechaDesde)
  if (filtros?.fechaHasta) q = q.lte('fecha', filtros.fechaHasta)
  if (!filtros?.verCancelados && filtros?.estado !== 'cancelado') {
    // Alineado con bot_ventas_periodo (mig029): excluye 'cancelado' e incluye
    // estado IS NULL, que un `.neq` pelado descartaría.
    q = q.or('estado.is.null,estado.neq.cancelado')
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

/*
 * Filtro "Con salvedad / Sin salvedad" (1598-b4). Antes se pedían aparte los ids de los pedidos
 * con salvedad y viajaban en la URL (`id=in.(…)`): pasados 700 el filtro dejaba de andar. Ahora es
 * un embed de PostgREST a `salvedades_items`, filtrado a las vigentes (no anuladas, #1180): «con»
 * es un `!inner` (semi-join) y «sin» el anti-join (`salvedades_items=is.null`). La RLS de
 * `salvedades_items` corre sola, como corría con la lista de ids.
 *
 * Trampa 5 de CLAUDE.md: `salvedades_items` tiene DOS FK a `pedidos` (`pedido_id` y
 * `pedido_reprogramado_id`). Sin el nombre de la FK, PostgREST da PGRST201 y cae TODA la lista.
 *
 * El embed va en el `select` y los filtros en `aplicarFiltroConSalvedad`. Cada consulta suma la
 * constante en su `.select(...)`: `selectStr + (conSalvedad === 'con_salvedad' ? EMBED_CON_SALVEDAD
 * : conSalvedad === 'sin_salvedad' ? EMBED_SIN_SALVEDAD : '')`. Con una suma, no con una función ni
 * con un ternario dentro de un template: el gate de embeds (`scripts/check-embeds.mjs`) lee
 * constantes, sumas y ternarios, y sin leerlo no prueba el embed contra PostgREST. Lo que vuelve embebido no se muestra:
 * `sinEmbedSalvedad` lo saca de cada fila.
 */
export const EMBED_CON_SALVEDAD = ',salvedades_items!salvedades_items_pedido_id_fkey!inner(id)'
export const EMBED_SIN_SALVEDAD = ',salvedades_items!salvedades_items_pedido_id_fkey(id)'

/** Los filtros del embed. La consulta tiene que haber sumado `embedFiltroSalvedad` a su select. */
export function aplicarFiltroConSalvedad<Q extends QueryFiltrablePedidos>(
  query: Q,
  conSalvedad: FiltrosPedidosState['conSalvedad'] | undefined,
): Q {
  if (conSalvedad !== 'con_salvedad' && conSalvedad !== 'sin_salvedad') return query
  const q = query.neq('salvedades_items.estado_resolucion', 'anulada')
  return conSalvedad === 'sin_salvedad' ? q.is('salvedades_items', null) : q
}

/** Saca de una fila lo que trajo el embed del filtro, para que nada lo muestre ni lo exporte. */
export function sinEmbedSalvedad<T extends object>(fila: T): T {
  if (!('salvedades_items' in fila)) return fila
  const { salvedades_items: _embed, ...resto } = fila as T & { salvedades_items?: unknown }
  return resto as T
}

/**
 * usePedidoStatsQuery
 *
 * Hook que calcula totales por estado/pago sobre TODOS los pedidos que coinciden
 * con los filtros activos (no sólo la página visible). Usa un SELECT ligero
 * (sin items/clientes) para mantener la respuesta pequeña.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import type { FiltrosPedidosState } from '../../types'
import { pedidosKeys, fetchPedidoIdsConSalvedad } from './usePedidosQuery'
import { construirFiltrosPedidos, aplicarFiltroConSalvedad } from '../../utils/construirFiltrosPedidos'
import { PAGINA_SUPABASE } from '../../utils/paginacion'

export interface PedidoStatsBucket {
  count: number
  monto: number
}

export interface PedidoStatsSummary {
  pendientes: PedidoStatsBucket
  enPreparacion: PedidoStatsBucket
  enCamino: PedidoStatsBucket
  entregados: PedidoStatsBucket
  impagos: PedidoStatsBucket
  total: PedidoStatsBucket
  /**
   * true si se llegó al tope de páginas antes de agotar los pedidos que
   * cumplen el filtro: los totales son un piso, no el número exacto (#524).
   */
  aproximado: boolean
}

const EMPTY_SUMMARY: PedidoStatsSummary = {
  pendientes: { count: 0, monto: 0 },
  enPreparacion: { count: 0, monto: 0 },
  enCamino: { count: 0, monto: 0 },
  entregados: { count: 0, monto: 0 },
  impagos: { count: 0, monto: 0 },
  total: { count: 0, monto: 0 },
  aproximado: false,
}

interface PedidoLiviano {
  estado: string | null
  estado_pago: string | null
  total: number | null
}

/**
 * Freno de mano de las cards: son un resumen visible, no un backup que tenga
 * que demostrar exactitud (para eso está `traerTodoVerificado`). Si se supera
 * este tope, mejor mostrar un total parcial marcado como aproximado que
 * colgar la pantalla trayendo la tabla entera.
 */
const STATS_TOPE_FILAS = 20_000

interface QueryPaginablePedidos {
  range(desde: number, hasta: number): PromiseLike<{ data: PedidoLiviano[] | null; error: { message: string } | null }>
}

/**
 * Pagina hasta agotar los pedidos que cumplen el filtro, con orden estable
 * por `id` (responsabilidad de quien arma `hacerQuery`). Antes esto pedía
 * `range(0, 9999)` en una sola llamada creyendo que el tope era 10.000;
 * PostgREST corta en 1.000 sin avisar, así que con la ventana por defecto
 * (~1.064 pedidos) las seis cards sumaban un subconjunto silencioso (#524).
 */
async function paginarStats(
  hacerQuery: () => QueryPaginablePedidos,
): Promise<{ filas: PedidoLiviano[]; aproximado: boolean }> {
  const filas: PedidoLiviano[] = []
  for (let desde = 0; desde < STATS_TOPE_FILAS; desde += PAGINA_SUPABASE) {
    const { data, error } = await hacerQuery().range(desde, desde + PAGINA_SUPABASE - 1)
    if (error) throw new Error(`No se pudieron calcular los totales de pedidos: ${error.message}`)

    const lote = data ?? []
    filas.push(...lote)

    if (lote.length < PAGINA_SUPABASE) return { filas, aproximado: false }
  }
  return { filas, aproximado: true }
}

async function fetchPedidoStats(
  filters?: Partial<FiltrosPedidosState>,
  search?: string,
): Promise<PedidoStatsSummary> {
  const hasSearch = !!(search && search.trim().length > 0)
  const selectStr = hasSearch
    ? 'estado, estado_pago, total, cliente:clientes!inner(id)'
    : 'estado, estado_pago, total'

  // conSalvedad necesita un round-trip previo a salvedades_items: no es un
  // filtro que se pueda encadenar solo (ver fetchPedidoIdsConSalvedad).
  let idsConSalvedad: number[] | null = null
  if (filters?.conSalvedad && filters.conSalvedad !== 'todos') {
    idsConSalvedad = await fetchPedidoIdsConSalvedad()
  }

  const armarQuery = () => {
    let query = supabase.from('pedidos').select(selectStr).order('id', { ascending: true })
    query = construirFiltrosPedidos(query, filters, search)
    query = aplicarFiltroConSalvedad(query, filters?.conSalvedad, idsConSalvedad)
    return query as unknown as QueryPaginablePedidos
  }

  const { filas, aproximado } = await paginarStats(armarQuery)

  const summary: PedidoStatsSummary = {
    pendientes: { count: 0, monto: 0 },
    enPreparacion: { count: 0, monto: 0 },
    enCamino: { count: 0, monto: 0 },
    entregados: { count: 0, monto: 0 },
    impagos: { count: 0, monto: 0 },
    total: { count: 0, monto: 0 },
    aproximado,
  }

  for (const p of filas) {
    const monto = p.total || 0
    summary.total.count += 1
    summary.total.monto += monto
    if (p.estado === 'pendiente') {
      summary.pendientes.count += 1
      summary.pendientes.monto += monto
    } else if (p.estado === 'en_preparacion') {
      summary.enPreparacion.count += 1
      summary.enPreparacion.monto += monto
    } else if (p.estado === 'asignado') {
      summary.enCamino.count += 1
      summary.enCamino.monto += monto
    } else if (p.estado === 'entregado') {
      summary.entregados.count += 1
      summary.entregados.monto += monto
    }
    if (p.estado_pago !== 'pagado') {
      summary.impagos.count += 1
      summary.impagos.monto += monto
    }
  }

  return summary
}

export function usePedidoStatsQuery(
  filters?: Partial<FiltrosPedidosState>,
  search?: string,
  enabled = true,
) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: [
      ...pedidosKeys.all(currentSucursalId),
      'stats',
      { ...filters, busqueda: search } as Partial<FiltrosPedidosState>,
    ],
    queryFn: () => fetchPedidoStats(filters, search),
    staleTime: 2 * 60 * 1000,
    enabled,
    placeholderData: EMPTY_SUMMARY,
  })
}

export { EMPTY_SUMMARY as EMPTY_PEDIDO_STATS_SUMMARY }

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
import { pedidosKeys } from './usePedidosQuery'

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
}

const EMPTY_SUMMARY: PedidoStatsSummary = {
  pendientes: { count: 0, monto: 0 },
  enPreparacion: { count: 0, monto: 0 },
  enCamino: { count: 0, monto: 0 },
  entregados: { count: 0, monto: 0 },
  impagos: { count: 0, monto: 0 },
  total: { count: 0, monto: 0 },
}

interface PedidoLiviano {
  estado: string | null
  estado_pago: string | null
  total: number | null
}

async function fetchPedidoStats(
  filters?: Partial<FiltrosPedidosState>,
  search?: string,
): Promise<PedidoStatsSummary> {
  const hasSearch = !!(search && search.trim().length > 0)
  const selectStr = hasSearch
    ? 'estado, estado_pago, total, cliente:clientes!inner(id)'
    : 'estado, estado_pago, total'

  let query = supabase.from('pedidos').select(selectStr)

  if (filters?.estado && filters.estado !== 'todos') {
    query = query.eq('estado', filters.estado)
  }
  if (filters?.estadoPago && filters.estadoPago !== 'todos') {
    query = query.eq('estado_pago', filters.estadoPago)
  }
  if (filters?.transportistaId && filters.transportistaId !== 'todos') {
    query = query.eq('transportista_id', filters.transportistaId)
  }
  if (filters?.fechaDesde) {
    query = query.gte('fecha', filters.fechaDesde)
  }
  if (filters?.fechaHasta) {
    query = query.lte('fecha', filters.fechaHasta)
  }
  if (!filters?.verCancelados) {
    query = query.neq('estado', 'cancelado')
  }
  if (filters?.fechaEntregaProgramada) {
    query = query.eq('fecha_entrega_programada', filters.fechaEntregaProgramada)
  }
  if (hasSearch) {
    const trimmed = search!.trim()
    query = query.or(
      `nombre_fantasia.ilike.%${trimmed}%,razon_social.ilike.%${trimmed}%,cuit.ilike.%${trimmed}%,direccion.ilike.%${trimmed}%`,
      { referencedTable: 'clientes' },
    )
  }

  // range amplio para cubrir filtros típicos sin paginación; si se supera,
  // aceptamos el truncado — las cards son una aproximación útil igual.
  query = query.range(0, 9999)

  const { data, error } = await query
  if (error) throw error

  const filas = (data || []) as unknown as PedidoLiviano[]
  const summary: PedidoStatsSummary = {
    pendientes: { count: 0, monto: 0 },
    enPreparacion: { count: 0, monto: 0 },
    enCamino: { count: 0, monto: 0 },
    entregados: { count: 0, monto: 0 },
    impagos: { count: 0, monto: 0 },
    total: { count: 0, monto: 0 },
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

/**
 * TanStack Query hooks para Métricas del Dashboard
 * Calcula métricas de ventas, productos y clientes con cache optimizado
 */
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { fechaLocalISO } from '../../utils/formatters'
import {
  addDiasISO,
  agregarMetricasPeriodo,
  serieVentas7Dias,
  ventanaAnterior,
  ventanaPeriodoDashboard,
  type PedidoMetricaRow,
} from '../../utils/metricasDashboard'
import type {
  DashboardMetricasExtended,
  ReportePreventista,
  PedidoDB
} from '../../types'

// Query keys
export const metricasKeys = {
  all: (sucursalId: number | null) => ['metricas', sucursalId] as const,
  dashboard: (
    sucursalId: number | null,
    periodo: string,
    usuarioId?: string | null,
    fechaDesde?: string | null,
    fechaHasta?: string | null
  ) =>
    [...metricasKeys.all(sucursalId), 'dashboard', periodo, usuarioId, fechaDesde, fechaHasta] as const,
  reportePreventistas: (sucursalId: number | null, fechaDesde?: string | null, fechaHasta?: string | null) =>
    [...metricasKeys.all(sucursalId), 'reporte-preventistas', fechaDesde, fechaHasta] as const,
}

type FiltroPeriodo = 'hoy' | 'semana' | 'mes' | 'anio' | 'historico' | 'personalizado'

interface MetricasParams {
  periodo: FiltroPeriodo | string
  fechaDesde?: string | null
  fechaHasta?: string | null
  usuarioId?: string | null
}

// Fetch functions
async function calcularMetricas(params: MetricasParams): Promise<DashboardMetricasExtended> {
  const { periodo, fechaDesde, fechaHasta, usuarioId } = params

  const hoyISO = fechaLocalISO()
  // Ventana [desde, hasta] sobre `pedidos.fecha` (fecha de entrega, editable):
  // filtrar por fecha server-side incluye los pedidos re-fechados (patrón del
  // fix de rutas PR #414) y elimina el viejo hack de +1 día sobre created_at
  // que perdía el último día del rango personalizado.
  const ventana = ventanaPeriodoDashboard(periodo, hoyISO, fechaDesde, fechaHasta)

  // -- Query principal del período (para 'historico' baja todo: intencional) --
  const principalPromise = (async () => {
    let query = supabase
      .from('pedidos')
      .select(`*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))`)
      .neq('estado', 'cancelado')
    if (usuarioId) query = query.eq('usuario_id', usuarioId)
    if (ventana.desde) query = query.gte('fecha', ventana.desde)
    if (ventana.hasta) query = query.lte('fecha', ventana.hasta)
    const { data, error } = await query.order('created_at', { ascending: false })
    if (error) throw error
    return (data as PedidoMetricaRow[]) || []
  })()

  // -- Período anterior de igual duración terminando el día antes (misma
  //    convención que el comparativo del RPC reporte_gerencial). Sin `desde`
  //    (historico) no hay comparación posible.
  const prev = ventana.desde ? ventanaAnterior(ventana.desde, ventana.hasta ?? hoyISO) : null
  const anteriorPromise = (async () => {
    if (!prev) return null
    let query = supabase
      .from('pedidos')
      .select('total, estado')
      .neq('estado', 'cancelado')
      .gte('fecha', prev.desde)
      .lte('fecha', prev.hasta)
    if (usuarioId) query = query.eq('usuario_id', usuarioId)
    const { data, error } = await query
    if (error) throw error
    return (data as Array<{ total: number | null; estado: string }>) || []
  })()

  // -- Últimos 7 días para el gráfico, SIEMPRE (ventana propia, independiente
  //    del período elegido). Mantiene "no cancelados": con entregado-only los
  //    días recientes se verían vacíos hasta cerrar el reparto.
  const seriePromise = (async () => {
    let query = supabase
      .from('pedidos')
      .select('total, fecha')
      .neq('estado', 'cancelado')
      .gte('fecha', addDiasISO(hoyISO, -6))
      .lte('fecha', hoyISO)
    if (usuarioId) query = query.eq('usuario_id', usuarioId)
    const { data, error } = await query
    if (error) throw error
    return (data as Array<{ total: number | null; fecha: string | null }>) || []
  })()

  const [pedidos, pedidosAnterior, filasSerie] = await Promise.all([
    principalPromise,
    anteriorPromise,
    seriePromise,
  ])

  return {
    ...agregarMetricasPeriodo(pedidos),
    ventasPeriodoAnterior: pedidosAnterior
      ? pedidosAnterior.filter(p => p.estado === 'entregado').reduce((s, p) => s + (p.total || 0), 0)
      : null,
    pedidosPeriodoAnterior: pedidosAnterior ? pedidosAnterior.length : null,
    ventasPorDia: serieVentas7Dias(filasSerie, hoyISO),
  }
}

async function calcularReportePreventistas(
  fechaDesde?: string | null,
  fechaHasta?: string | null
): Promise<ReportePreventista[]> {
  let query = supabase.from('pedidos').select(`*, items:pedido_items(*)`)

  if (fechaDesde) {
    query = query.gte('fecha', fechaDesde)
  }
  if (fechaHasta) {
    query = query.lte('fecha', fechaHasta)
  }

  const { data: pedidos, error } = await query
  if (error) throw error

  if (!pedidos || pedidos.length === 0) {
    return []
  }

  const pedidosTyped = (pedidos as PedidoDB[]).filter(p => p.estado !== 'cancelado')
  const usuarioIds = Array.from(new Set(pedidosTyped.map(p => p.usuario_id).filter(Boolean))) as string[]

  const { data: usuarios } = await supabase.from('perfiles').select('id, nombre, email').in('id', usuarioIds)
  const usuariosMap: Record<string, { id: string; nombre: string; email: string }> = {}
  ;((usuarios || []) as Array<{ id: string; nombre: string; email: string }>).forEach(u => {
    usuariosMap[u.id] = u
  })

  const reportePorPreventista: Record<string, ReportePreventista> = {}

  pedidosTyped.forEach(pedido => {
    const usuarioId = pedido.usuario_id
    if (!usuarioId) return

    const usuario = usuariosMap[usuarioId]
    const usuarioNombre = usuario?.nombre || 'Usuario desconocido'

    if (!reportePorPreventista[usuarioId]) {
      reportePorPreventista[usuarioId] = {
        id: usuarioId,
        nombre: usuarioNombre,
        email: usuario?.email || 'N/A',
        totalVentas: 0,
        cantidadPedidos: 0,
        pedidosPendientes: 0,
        pedidosAsignados: 0,
        pedidosEntregados: 0,
        totalPagado: 0,
        totalPendiente: 0
      }
    }

    reportePorPreventista[usuarioId].totalVentas += pedido.total || 0
    reportePorPreventista[usuarioId].cantidadPedidos += 1

    if (pedido.estado === 'pendiente') reportePorPreventista[usuarioId].pedidosPendientes += 1
    if (pedido.estado === 'asignado') reportePorPreventista[usuarioId].pedidosAsignados += 1
    if (pedido.estado === 'entregado') reportePorPreventista[usuarioId].pedidosEntregados += 1

    if (pedido.estado_pago === 'pagado') reportePorPreventista[usuarioId].totalPagado += pedido.total || 0
    else if (pedido.estado_pago === 'pendiente') reportePorPreventista[usuarioId].totalPendiente += pedido.total || 0
  })

  return Object.values(reportePorPreventista).sort((a, b) => b.totalVentas - a.totalVentas)
}

// Hooks

/**
 * Hook para obtener métricas del dashboard
 */
export function useMetricasQuery(
  periodo: FiltroPeriodo | string = 'mes',
  usuarioId?: string | null,
  fechaDesde?: string | null,
  fechaHasta?: string | null,
  enabled = true
) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: metricasKeys.dashboard(currentSucursalId, periodo, usuarioId, fechaDesde, fechaHasta),
    queryFn: () => calcularMetricas({ periodo, fechaDesde, fechaHasta, usuarioId }),
    staleTime: 2 * 60 * 1000, // 2 minutos - métricas cambian frecuentemente
    gcTime: 10 * 60 * 1000,
    enabled,
  })
}

/**
 * Hook para obtener reporte de preventistas
 */
export function useReportePreventistasQuery(
  fechaDesde?: string | null,
  fechaHasta?: string | null,
  enabled = true
) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: metricasKeys.reportePreventistas(currentSucursalId, fechaDesde, fechaHasta),
    queryFn: () => calcularReportePreventistas(fechaDesde, fechaHasta),
    enabled,
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Hook para invalidar métricas manualmente
 */
export function useInvalidateMetricas() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return () => {
    queryClient.invalidateQueries({ queryKey: metricasKeys.all(currentSucursalId) })
  }
}

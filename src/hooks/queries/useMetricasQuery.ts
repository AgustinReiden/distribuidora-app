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
import { traerTodo } from '../../utils/paginacion'

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
  // Paginado: un mes típico ya son ~1.064 pedidos, así que sin esto los KPIs
  // del dashboard se calculaban sobre un subconjunto arbitrario. El desempate
  // por `id` hace falta para que la paginación sea estable: `created_at` solo
  // no es único.
  const principalPromise = traerTodo<PedidoMetricaRow>(
    () => {
      let query = supabase
        .from('pedidos')
        .select(`*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))`)
        .neq('estado', 'cancelado')
      if (usuarioId) query = query.eq('usuario_id', usuarioId)
      if (ventana.desde) query = query.gte('fecha', ventana.desde)
      if (ventana.hasta) query = query.lte('fecha', ventana.hasta)
      return query.order('created_at', { ascending: false }).order('id')
    },
    { etiqueta: 'pedidos del dashboard' },
  )

  // -- Período anterior de igual duración terminando el día antes (misma
  //    convención que el comparativo del RPC reporte_gerencial). Sin `desde`
  //    (historico) no hay comparación posible.
  const prev = ventana.desde ? ventanaAnterior(ventana.desde, ventana.hasta ?? hoyISO) : null
  //
  //    Paginado por lo mismo que la query principal: el período anterior tiene
  //    la misma duración que el elegido, así que un mes son ~1.064 pedidos y ya
  //    pasaba el tope. La comparación "vs período anterior" salía calculada
  //    sobre 1.000 pedidos contra el total real del período actual: dos
  //    universos de distinto tamaño, o sea una variación inventada.
  const anteriorPromise = (async () => {
    if (!prev) return null
    return traerTodo<{ total: number | null; estado: string }>(
      () => {
        let query = supabase
          .from('pedidos')
          .select('total, estado')
          .neq('estado', 'cancelado')
          .gte('fecha', prev.desde)
          .lte('fecha', prev.hasta)
        if (usuarioId) query = query.eq('usuario_id', usuarioId)
        return query.order('id')
      },
      { etiqueta: 'pedidos del período anterior' },
    )
  })()

  // -- Últimos 7 días para el gráfico, SIEMPRE (ventana propia, independiente
  //    del período elegido). Mantiene "no cancelados": con entregado-only los
  //    días recientes se verían vacíos hasta cerrar el reparto.
  //    Paginado aunque hoy 7 días sean ~213 pedidos: es la misma consulta con
  //    otra ventana, y lo que la salva es el volumen, no el código.
  const seriePromise = traerTodo<{ total: number | null; fecha: string | null }>(
    () => {
      let query = supabase
        .from('pedidos')
        .select('total, fecha')
        .neq('estado', 'cancelado')
        .gte('fecha', addDiasISO(hoyISO, -6))
        .lte('fecha', hoyISO)
      if (usuarioId) query = query.eq('usuario_id', usuarioId)
      return query.order('id')
    },
    { etiqueta: 'pedidos del gráfico' },
  )

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

/**
 * Ventas por vendedor. La agregación la hace la base (mig 208): devuelve una
 * fila por vendedor en vez de traer todos los pedidos del período con sus
 * items para sumarlos acá.
 *
 * OJO, cambia dos números respecto de la versión que corría en el navegador:
 * "Pagado" y "Pendiente" ahora salen de `monto_pagado` y no de baldes por
 * `estado_pago`. La versión vieja usaba el total ENTERO del pedido según su
 * estado, así que ignoraba los pagos parciales y dejaba afuera de los dos
 * baldes a los pedidos en cualquier otro estado. En agosto eso eran $250.050
 * que no aparecían en ninguna columna: pagado + pendiente no daba las ventas.
 * Ahora cierran exacto.
 */
async function calcularReportePreventistas(
  fechaDesde?: string | null,
  fechaHasta?: string | null
): Promise<ReportePreventista[]> {
  const { data, error } = await supabase.rpc('reporte_ventas_por_preventista', {
    p_desde: fechaDesde ?? null,
    p_hasta: fechaHasta ?? null,
    p_sucursal_id: null,
  })
  if (error) throw error
  return (data ?? []) as ReportePreventista[]
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

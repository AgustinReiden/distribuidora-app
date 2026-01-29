/**
 * TanStack Query hooks para Métricas del Dashboard
 * Calcula métricas de ventas, productos y clientes con cache optimizado
 */
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import type {
  DashboardMetricasExtended,
  ReportePreventista,
  ProductoVendido,
  ClienteActivo,
  VentaPorDia,
  PedidosPorEstado,
  PedidoDB
} from '../../types'

// Query keys
export const metricasKeys = {
  all: ['metricas'] as const,
  dashboard: (periodo: string, usuarioId?: string | null) =>
    [...metricasKeys.all, 'dashboard', periodo, usuarioId] as const,
  reportePreventistas: (fechaDesde?: string | null, fechaHasta?: string | null) =>
    [...metricasKeys.all, 'reporte-preventistas', fechaDesde, fechaHasta] as const,
}

interface PedidoWithRelations {
  id: string
  cliente_id: string
  cliente?: { nombre_fantasia?: string } | null
  usuario_id?: string
  estado: string
  estado_pago?: string
  total: number
  monto_pagado?: number
  created_at?: string
  items?: Array<{
    producto_id: string
    cantidad: number
    producto?: { nombre?: string } | null
  }>
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

  let query = supabase
    .from('pedidos')
    .select(`*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))`)

  if (usuarioId) {
    query = query.eq('usuario_id', usuarioId)
  }

  const { data: todosPedidos, error } = await query.order('created_at', { ascending: false })

  if (error) throw error
  if (!todosPedidos) {
    return {
      ventasPeriodo: 0,
      pedidosPeriodo: 0,
      productosMasVendidos: [],
      clientesMasActivos: [],
      pedidosPorEstado: { pendiente: 0, en_preparacion: 0, asignado: 0, entregado: 0 },
      ventasPorDia: []
    }
  }

  const pedidosTyped = todosPedidos as PedidoWithRelations[]

  const hoy = new Date()
  const hoyStr = hoy.toISOString().split('T')[0]
  let fechaInicioStr: string | null = null

  switch (periodo) {
    case 'hoy':
      fechaInicioStr = hoyStr
      break
    case 'semana': {
      const hace7Dias = new Date()
      hace7Dias.setDate(hace7Dias.getDate() - 7)
      fechaInicioStr = hace7Dias.toISOString().split('T')[0]
      break
    }
    case 'mes': {
      const inicioMes = new Date(hoy.getFullYear(), hoy.getMonth(), 1)
      fechaInicioStr = inicioMes.toISOString().split('T')[0]
      break
    }
    case 'anio': {
      const inicioAnio = new Date(hoy.getFullYear(), 0, 1)
      fechaInicioStr = inicioAnio.toISOString().split('T')[0]
      break
    }
    case 'personalizado':
      fechaInicioStr = fechaDesde || null
      break
    case 'historico':
    default:
      fechaInicioStr = null
      break
  }

  let pedidosFiltrados = pedidosTyped
  if (fechaInicioStr) {
    pedidosFiltrados = pedidosTyped.filter(p => (p.created_at?.split('T')[0] ?? '') >= fechaInicioStr!)
  }
  if (periodo === 'personalizado' && fechaHasta) {
    pedidosFiltrados = pedidosFiltrados.filter(p => (p.created_at?.split('T')[0] ?? '') <= fechaHasta)
  }

  // Productos más vendidos
  const productosVendidos: Record<string, ProductoVendido> = {}
  pedidosFiltrados.forEach(p => p.items?.forEach(i => {
    const id = i.producto_id
    if (!productosVendidos[id]) productosVendidos[id] = { id, nombre: i.producto?.nombre || 'N/A', cantidad: 0 }
    productosVendidos[id].cantidad += i.cantidad
  }))
  const topProductos: ProductoVendido[] = Object.values(productosVendidos)
    .sort((a, b) => b.cantidad - a.cantidad)
    .slice(0, 5)

  // Clientes más activos
  const clientesActivos: Record<string, ClienteActivo> = {}
  pedidosFiltrados.forEach(p => {
    const id = p.cliente_id
    if (!clientesActivos[id]) clientesActivos[id] = {
      id,
      nombre: (p.cliente as { nombre_fantasia?: string })?.nombre_fantasia || 'N/A',
      total: 0,
      pedidos: 0
    }
    clientesActivos[id].total += p.total || 0
    clientesActivos[id].pedidos += 1
  })
  const topClientes: ClienteActivo[] = Object.values(clientesActivos)
    .sort((a, b) => b.total - a.total)
    .slice(0, 5)

  // Ventas por día (últimos 7 días)
  const ventasPorDia: VentaPorDia[] = []
  for (let i = 6; i >= 0; i--) {
    const fecha = new Date()
    fecha.setDate(fecha.getDate() - i)
    const fechaStr = fecha.toISOString().split('T')[0]
    const pedidosDia = pedidosTyped.filter(p => p.created_at?.split('T')[0] === fechaStr)
    ventasPorDia.push({
      dia: fecha.toLocaleDateString('es-AR', { weekday: 'short' }),
      ventas: pedidosDia.reduce((s, p) => s + (p.total || 0), 0),
      pedidos: pedidosDia.length
    })
  }

  // Pedidos por estado
  const pedidosPorEstado: PedidosPorEstado = {
    pendiente: pedidosTyped.filter(p => p.estado === 'pendiente').length,
    en_preparacion: pedidosTyped.filter(p => p.estado === 'en_preparacion').length,
    asignado: pedidosTyped.filter(p => p.estado === 'asignado').length,
    entregado: pedidosTyped.filter(p => p.estado === 'entregado').length
  }

  return {
    ventasPeriodo: pedidosFiltrados.reduce((s, p) => s + (p.total || 0), 0),
    pedidosPeriodo: pedidosFiltrados.length,
    productosMasVendidos: topProductos,
    clientesMasActivos: topClientes,
    pedidosPorEstado,
    ventasPorDia
  }
}

async function calcularReportePreventistas(
  fechaDesde?: string | null,
  fechaHasta?: string | null
): Promise<ReportePreventista[]> {
  let query = supabase.from('pedidos').select(`*, items:pedido_items(*)`)

  if (fechaDesde) {
    query = query.gte('created_at', `${fechaDesde}T00:00:00`)
  }
  if (fechaHasta) {
    query = query.lte('created_at', `${fechaHasta}T23:59:59`)
  }

  const { data: pedidos, error } = await query
  if (error) throw error

  if (!pedidos || pedidos.length === 0) {
    return []
  }

  const pedidosTyped = pedidos as PedidoDB[]
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
  fechaHasta?: string | null
) {
  return useQuery({
    queryKey: metricasKeys.dashboard(periodo, usuarioId),
    queryFn: () => calcularMetricas({ periodo, fechaDesde, fechaHasta, usuarioId }),
    staleTime: 2 * 60 * 1000, // 2 minutos - métricas cambian frecuentemente
    gcTime: 10 * 60 * 1000,
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
  return useQuery({
    queryKey: metricasKeys.reportePreventistas(fechaDesde, fechaHasta),
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

  return () => {
    queryClient.invalidateQueries({ queryKey: metricasKeys.all })
  }
}

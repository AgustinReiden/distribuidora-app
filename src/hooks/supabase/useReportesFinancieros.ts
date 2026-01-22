import { useState } from 'react'
import { supabase, notifyError } from './base'
import type {
  ReporteCuentaPorCobrar,
  ReporteRentabilidad,
  ProductoRentabilidad,
  TotalesRentabilidad,
  VentaPorCliente,
  VentaPorZona,
  AgingDeuda,
  UseReportesFinancierosReturn,
  ClienteDB,
  PedidoDB,
  PagoDB,
  ProductoDB
} from '../../types'

interface PedidoWithItems {
  id: string;
  cliente_id: string;
  estado: string;
  estado_pago?: string;
  total: number;
  created_at?: string;
  items?: Array<{
    cantidad: number;
    precio_unitario: number;
    subtotal?: number;
    producto?: ProductoDB | null;
  }>;
}

interface PedidoWithCliente {
  id: string;
  cliente_id: string;
  estado: string;
  estado_pago?: string;
  total: number;
  created_at?: string;
  cliente?: ClienteDB | null;
}

interface ProductoStatsMap {
  [key: string]: ProductoRentabilidad;
}

interface ClienteStatsMap {
  [key: string]: VentaPorCliente;
}

interface ZonaStatsMap {
  [key: string]: {
    zona: string;
    cantidadPedidos: number;
    totalVentas: number;
    clientes: Set<string>;
  };
}

export function useReportesFinancieros(): UseReportesFinancierosReturn {
  const [loading, setLoading] = useState<boolean>(false)

  const generarReporteCuentasPorCobrar = async (): Promise<ReporteCuentaPorCobrar[]> => {
    setLoading(true)
    try {
      const { data: clientes, error: errorClientes } = await supabase
        .from('clientes')
        .select('*')
        .order('nombre_fantasia')
      if (errorClientes) throw errorClientes

      const { data: pedidos, error: errorPedidos } = await supabase
        .from('pedidos')
        .select('*')
        .neq('estado_pago', 'pagado')
      if (errorPedidos) throw errorPedidos

      const { data: pagos, error: errorPagos } = await supabase
        .from('pagos')
        .select('*')
      if (errorPagos && !errorPagos.message.includes('does not exist')) throw errorPagos

      const clientesTyped = (clientes || []) as ClienteDB[]
      const pedidosTyped = (pedidos || []) as PedidoDB[]
      const pagosTyped = (pagos || []) as PagoDB[]

      const hoy = new Date()
      const reporte: ReporteCuentaPorCobrar[] = clientesTyped.map(cliente => {
        const pedidosCliente = pedidosTyped.filter(p => p.cliente_id === cliente.id)
        const pagosCliente = pagosTyped.filter(p => p.cliente_id === cliente.id)

        const totalDeuda = pedidosCliente.reduce((s, p) => s + (p.total || 0), 0)
        const totalPagado = pagosCliente.reduce((s, p) => s + (p.monto || 0), 0)
        const saldoPendiente = totalDeuda - totalPagado

        let corriente = 0, vencido30 = 0, vencido60 = 0, vencido90 = 0
        pedidosCliente.forEach(p => {
          const fechaPedido = new Date(p.created_at || 0)
          const diasCredito = cliente.dias_credito || 30
          const fechaVencimiento = new Date(fechaPedido)
          fechaVencimiento.setDate(fechaVencimiento.getDate() + diasCredito)
          const diasVencido = Math.floor((hoy.getTime() - fechaVencimiento.getTime()) / (1000 * 60 * 60 * 24))

          if (diasVencido <= 0) corriente += p.total || 0
          else if (diasVencido <= 30) vencido30 += p.total || 0
          else if (diasVencido <= 60) vencido60 += p.total || 0
          else vencido90 += p.total || 0
        })

        const aging: AgingDeuda = { corriente, vencido30, vencido60, vencido90 }

        return {
          cliente,
          totalDeuda,
          totalPagado,
          saldoPendiente,
          limiteCredito: cliente.limite_credito || 0,
          creditoDisponible: (cliente.limite_credito || 0) - saldoPendiente,
          aging,
          pedidosPendientes: pedidosCliente.length
        }
      }).filter(r => r.saldoPendiente > 0).sort((a, b) => b.saldoPendiente - a.saldoPendiente)

      return reporte
    } catch (error) {
      notifyError('Error al generar reporte: ' + (error as Error).message)
      return []
    } finally {
      setLoading(false)
    }
  }

  const generarReporteRentabilidad = async (
    fechaDesde: string | null = null,
    fechaHasta: string | null = null
  ): Promise<ReporteRentabilidad> => {
    setLoading(true)
    try {
      let query = supabase.from('pedidos').select(`*, items:pedido_items(*, producto:productos(*))`)
      if (fechaDesde) query = query.gte('created_at', `${fechaDesde}T00:00:00`)
      if (fechaHasta) query = query.lte('created_at', `${fechaHasta}T23:59:59`)

      const { data: pedidos, error } = await query
      if (error) throw error

      const pedidosTyped = (pedidos || []) as PedidoWithItems[]

      const productoStats: ProductoStatsMap = {}
      pedidosTyped.forEach(p => {
        p.items?.forEach(item => {
          const prod = item.producto
          if (!prod) return
          const id = prod.id
          if (!productoStats[id]) {
            productoStats[id] = {
              id,
              nombre: prod.nombre,
              codigo: prod.codigo,
              cantidadVendida: 0,
              ingresos: 0,
              costos: 0,
              margen: 0,
              margenPorcentaje: 0
            }
          }
          productoStats[id].cantidadVendida += item.cantidad
          productoStats[id].ingresos += item.subtotal || (item.cantidad * item.precio_unitario)
          const costoUnitario = prod.costo_con_iva || prod.costo_sin_iva || 0
          productoStats[id].costos += costoUnitario * item.cantidad
        })
      })

      const reporteProductos: ProductoRentabilidad[] = Object.values(productoStats).map(p => ({
        ...p,
        margen: p.ingresos - p.costos,
        margenPorcentaje: p.ingresos > 0 ? ((p.ingresos - p.costos) / p.ingresos * 100) : 0
      })).sort((a, b) => b.margen - a.margen)

      const totales: TotalesRentabilidad = {
        ingresosTotales: reporteProductos.reduce((s, p) => s + p.ingresos, 0),
        costosTotales: reporteProductos.reduce((s, p) => s + p.costos, 0),
        margenTotal: reporteProductos.reduce((s, p) => s + p.margen, 0),
        cantidadPedidos: pedidosTyped.length,
        margenPorcentaje: 0
      }
      totales.margenPorcentaje = totales.ingresosTotales > 0
        ? (totales.margenTotal / totales.ingresosTotales * 100)
        : 0

      return { productos: reporteProductos, totales }
    } catch (error) {
      notifyError('Error al generar reporte: ' + (error as Error).message)
      return {
        productos: [],
        totales: {
          ingresosTotales: 0,
          costosTotales: 0,
          margenTotal: 0,
          cantidadPedidos: 0,
          margenPorcentaje: 0
        }
      }
    } finally {
      setLoading(false)
    }
  }

  const generarReporteVentasPorCliente = async (
    fechaDesde: string | null = null,
    fechaHasta: string | null = null
  ): Promise<VentaPorCliente[]> => {
    setLoading(true)
    try {
      let query = supabase.from('pedidos').select(`*, cliente:clientes(*)`)
      if (fechaDesde) query = query.gte('created_at', `${fechaDesde}T00:00:00`)
      if (fechaHasta) query = query.lte('created_at', `${fechaHasta}T23:59:59`)

      const { data: pedidos, error } = await query
      if (error) throw error

      const pedidosTyped = (pedidos || []) as PedidoWithCliente[]

      const clienteStats: ClienteStatsMap = {}
      pedidosTyped.forEach(p => {
        const clienteId = p.cliente_id
        if (!clienteStats[clienteId]) {
          clienteStats[clienteId] = {
            cliente: p.cliente || null,
            cantidadPedidos: 0,
            totalVentas: 0,
            pedidosPagados: 0,
            pedidosPendientes: 0
          }
        }
        clienteStats[clienteId].cantidadPedidos += 1
        clienteStats[clienteId].totalVentas += p.total || 0
        if (p.estado_pago === 'pagado') clienteStats[clienteId].pedidosPagados += 1
        else clienteStats[clienteId].pedidosPendientes += 1
      })

      return Object.values(clienteStats).sort((a, b) => b.totalVentas - a.totalVentas)
    } catch {
      return []
    } finally {
      setLoading(false)
    }
  }

  const generarReporteVentasPorZona = async (
    fechaDesde: string | null = null,
    fechaHasta: string | null = null
  ): Promise<VentaPorZona[]> => {
    setLoading(true)
    try {
      let query = supabase.from('pedidos').select(`*, cliente:clientes(*)`)
      if (fechaDesde) query = query.gte('created_at', `${fechaDesde}T00:00:00`)
      if (fechaHasta) query = query.lte('created_at', `${fechaHasta}T23:59:59`)

      const { data: pedidos, error } = await query
      if (error) throw error

      const pedidosTyped = (pedidos || []) as PedidoWithCliente[]

      const zonaStats: ZonaStatsMap = {}
      pedidosTyped.forEach(p => {
        const zona = p.cliente?.zona || 'Sin zona'
        if (!zonaStats[zona]) {
          zonaStats[zona] = {
            zona,
            cantidadPedidos: 0,
            totalVentas: 0,
            clientes: new Set<string>()
          }
        }
        zonaStats[zona].cantidadPedidos += 1
        zonaStats[zona].totalVentas += p.total || 0
        zonaStats[zona].clientes.add(p.cliente_id)
      })

      return Object.values(zonaStats).map(z => ({
        zona: z.zona,
        cantidadPedidos: z.cantidadPedidos,
        totalVentas: z.totalVentas,
        cantidadClientes: z.clientes.size,
        ticketPromedio: z.cantidadPedidos > 0 ? z.totalVentas / z.cantidadPedidos : 0
      })).sort((a, b) => b.totalVentas - a.totalVentas)
    } catch {
      return []
    } finally {
      setLoading(false)
    }
  }

  return {
    loading,
    generarReporteCuentasPorCobrar,
    generarReporteRentabilidad,
    generarReporteVentasPorCliente,
    generarReporteVentasPorZona
  }
}

/**
 * "Total comprado" de la ficha de cliente, con la definición de venta del
 * proyecto (mig 241, #980): `estado = 'entregado'`, `canal <> 'cambio'`, por
 * `pedidos.fecha`. Un pedido tomado y no entregado no es venta todavía.
 *
 * Es una suma sobre toda la historia del cliente, así que el corte de día
 * (`fecha`, no `created_at` en UTC) no mueve el total; sí importaría si algún
 * día se filtra por período, por eso las filas traen `fecha`.
 *
 * Lo pendiente de entrega reusa `agregarMetricasPeriodo`, la misma cuenta del
 * Dashboard ("+$X en curso (N)"): todo lo no entregado y no cancelado.
 */
import { agregarMetricasPeriodo } from './metricasDashboard'

export interface PedidoVentaCliente {
  id: string
  cliente_id: string
  estado: string
  canal?: string | null
  total: number | null
  fecha?: string | null
  created_at?: string | null
}

export interface VentaCliente {
  totalComprado: number
  cantidadCompras: number
  pendienteEntrega: number
  pedidosPendientesEntrega: number
}

export function calcularVentaCliente(pedidos: PedidoVentaCliente[]): VentaCliente {
  const ventas = pedidos.filter(p => p.estado === 'entregado' && p.canal !== 'cambio')
  const { ventasEnCurso, pedidosEnCurso } = agregarMetricasPeriodo(pedidos)
  return {
    totalComprado: ventas.reduce((s, p) => s + (p.total || 0), 0),
    cantidadCompras: ventas.length,
    pendienteEntrega: ventasEnCurso,
    pedidosPendientesEntrega: pedidosEnCurso,
  }
}

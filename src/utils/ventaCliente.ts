/**
 * "Total comprado" de la ficha de cliente, con la definición de venta del
 * proyecto (mig 241, #980): `estado = 'entregado'`, `canal <> 'cambio'`, por
 * `pedidos.fecha`, y `tipo_factura <> 'VB'`. Un pedido tomado y no entregado no es
 * venta todavía. Un vale blanco (VB: consumo interno a costo hacia una empresa propia)
 * tampoco es venta: va aparte, en `consumoInterno`.
 *
 * Es una suma sobre toda la historia del cliente, así que el corte de día
 * (`fecha`, no `created_at` en UTC) no mueve el total; sí importaría si algún
 * día se filtra por período, por eso las filas traen `fecha`.
 *
 * Lo pendiente de entrega reusa `agregarMetricasPeriodo`, la misma cuenta del
 * Dashboard ("+$X en curso (N)"): todo lo no entregado y no cancelado.
 */
import { agregarMetricasPeriodo } from './metricasDashboard'
import { esTipoVB } from './valeBlanco'

export interface PedidoVentaCliente {
  id: string
  cliente_id: string
  estado: string
  canal?: string | null
  /** 'VB' = vale blanco (consumo interno): no es venta, se informa aparte. */
  tipo_factura?: string | null
  total: number | null
  fecha?: string | null
  created_at?: string | null
}

export interface VentaCliente {
  totalComprado: number
  cantidadCompras: number
  pendienteEntrega: number
  pedidosPendientesEntrega: number
  /** Vales blancos entregados (a costo): línea propia, fuera de la venta. */
  consumoInterno: { monto: number; cantidad: number }
}

export const esValeBlanco = (p: { tipo_factura?: string | null }): boolean => esTipoVB(p.tipo_factura)

export function calcularVentaCliente(pedidos: PedidoVentaCliente[]): VentaCliente {
  const ventas = pedidos.filter(p => p.estado === 'entregado' && p.canal !== 'cambio' && !esValeBlanco(p))
  const vales = pedidos.filter(p => p.estado === 'entregado' && p.canal !== 'cambio' && esValeBlanco(p))
  // Un VB nace entregado, así que no tiene "en curso"; igual se lo saca por si acaso.
  const { ventasEnCurso, pedidosEnCurso } = agregarMetricasPeriodo(pedidos.filter(p => !esValeBlanco(p)))
  return {
    consumoInterno: {
      monto: vales.reduce((s, p) => s + (p.total || 0), 0),
      cantidad: vales.length,
    },
    totalComprado: ventas.reduce((s, p) => s + (p.total || 0), 0),
    cantidadCompras: ventas.length,
    pendienteEntrega: ventasEnCurso,
    pedidosPendientesEntrega: pedidosEnCurso,
  }
}

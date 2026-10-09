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
 * Dashboard ("+$X en curso (N)"): todo lo no entregado y no cancelado, sin canjes.
 *
 * "Días sin comprar" y "frecuencia de compra" son métricas de COMPRA: salen sólo de
 * las ventas (`calcularRitmoCompra`), no de cualquier pedido activo.
 */
import { agregarMetricasPeriodo, diffDiasISO } from './metricasDashboard'
import { fechaLocalISO } from './formatters'
import { esTipoVB } from './valeBlanco'

export interface PedidoVentaCliente {
  id: string
  cliente_id: string
  estado: string
  estado_pago?: string | null
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
  /** Ventas (la misma base que `cantidadCompras`) con `estado_pago = 'pagado'`. */
  pedidosPagados: number
  pendienteEntrega: number
  pedidosPendientesEntrega: number
  /** Vales blancos entregados (a costo): línea propia, fuera de la venta. */
  consumoInterno: { monto: number; cantidad: number }
}

export const esValeBlanco = (p: { tipo_factura?: string | null }): boolean => esTipoVB(p.tipo_factura)

const esVenta = (p: PedidoVentaCliente): boolean =>
  p.estado === 'entregado' && p.canal !== 'cambio' && !esValeBlanco(p)

export function calcularVentaCliente(pedidos: PedidoVentaCliente[]): VentaCliente {
  const ventas = pedidos.filter(esVenta)
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
    pedidosPagados: ventas.filter(p => p.estado_pago === 'pagado').length,
    pendienteEntrega: ventasEnCurso,
    pedidosPendientesEntrega: pedidosEnCurso,
  }
}

export interface RitmoCompra {
  /** Días entre la última venta y hoy; null si el cliente nunca compró. */
  diasDesdeUltimaCompra: number | null
  /** Ventas por mes entre la primera y la última venta; 0 con menos de 2 ventas. */
  frecuenciaCompra: number
}

/** Día de la venta: `pedidos.fecha` (día argentino). Si falta, el día argentino de `created_at`, no su corte UTC. */
const diaDeVenta = (p: PedidoVentaCliente): string | null => {
  if (p.fecha) return p.fecha
  return p.created_at ? fechaLocalISO(new Date(p.created_at)) : null
}

/**
 * "Días sin comprar" y "frecuencia de compra" de la ficha, con la definición de
 * venta de la mig 241 (entregado, canal <> 'cambio', no VB) y fechadas por
 * `pedidos.fecha`. Un pendiente, un canje, un VB o un cancelado no son una compra:
 * no resetean los días ni suman a la frecuencia. `hoyISO` es la fecha local
 * argentina ('YYYY-MM-DD'). La frecuencia es ventas / meses entre la primera y la
 * última (mes de 30 días, piso de 1 mes).
 */
export function calcularRitmoCompra(pedidos: PedidoVentaCliente[], hoyISO: string): RitmoCompra {
  const dias = pedidos
    .filter(esVenta)
    .map(diaDeVenta)
    .filter((d): d is string => d !== null)
    .sort()
  if (dias.length === 0) return { diasDesdeUltimaCompra: null, frecuenciaCompra: 0 }

  const primera = dias[0]
  const ultima = dias[dias.length - 1]
  let frecuenciaCompra = 0
  if (dias.length > 1) {
    const meses = Math.max(1, diffDiasISO(primera, ultima) / 30)
    frecuenciaCompra = dias.length / meses
  }
  // `fecha` es editable: una venta re-fechada a futuro no deja los días en negativo.
  return { diasDesdeUltimaCompra: Math.max(0, diffDiasISO(ultima, hoyISO)), frecuenciaCompra }
}

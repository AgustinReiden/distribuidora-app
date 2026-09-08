import { useState } from 'react'
import { supabase, notifyError } from './base'
import type {
  ReporteCuentaPorCobrar,
  ReporteRentabilidad,
  ProductoRentabilidad,
  TotalesRentabilidad,
  AgingDeuda,
  UseReportesFinancierosReturn,
  ClienteDB,
  PedidoDB,
  PagoDB,
  ProductoDB
} from '../../types'
import { costoCanonicoUnitario } from '../../utils/costoCanonico'
import { traerTodo } from '../../utils/paginacion'
import { armarCuentasPorCobrar } from '../../utils/cuentasPorCobrar'

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

interface ProductoStatsMap {
  [key: string]: ProductoRentabilidad;
}

export function useReportesFinancieros(): UseReportesFinancierosReturn {
  const [loading, setLoading] = useState<boolean>(false)

  const generarReporteCuentasPorCobrar = async (): Promise<ReporteCuentaPorCobrar[]> => {
    setLoading(true)
    try {
      // Los INACTIVOS entran a propósito: un informe de deuda que esconde al que
      // debe y ya no opera no sirve para cobrarle (baja lógica, CLAUDE.md).
      const clientes = await traerTodo<ClienteDB>(
        () => supabase.from('clientes').select('*').order('id'),
        { etiqueta: 'clientes' },
      )

      // Ya NO se leen los pagos acá. El saldo se arma pedido por pedido con
      // `total - monto_pagado`; leer el histórico de pagos del cliente era
      // justamente el bug (#521): se le restaba a la deuda de los impagos toda
      // la plata que el cliente pagó en su vida.
      const pedidos = await traerTodo<PedidoDB>(
        () => supabase
          .from('pedidos')
          .select('id, cliente_id, total, monto_pagado, estado, fecha, fecha_entrega, created_at')
          .neq('estado_pago', 'pagado')
          .order('id'),
        { etiqueta: 'pedidos impagos' },
      )

      return armarCuentasPorCobrar(clientes, pedidos) as unknown as ReporteCuentaPorCobrar[]
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
      // Paginado: un solo mes ya pasa las 1.000 filas de PostgREST, así que sin
      // esto el margen se calculaba sobre un subconjunto arbitrario.
      const pedidosTyped = await traerTodo<PedidoWithItems>(
        () => {
          let q = supabase.from('pedidos').select(`*, items:pedido_items(*, producto:productos(*))`)
            .neq('estado', 'cancelado')
          if (fechaDesde) q = q.gte('created_at', `${fechaDesde}T00:00:00`)
          if (fechaHasta) q = q.lte('created_at', `${fechaHasta}T23:59:59`)
          return q.order('id')
        },
        { etiqueta: 'pedidos para rentabilidad' },
      )

      const productoStats: ProductoStatsMap = {}
      let ventasBrutas = 0
      let ivaDiscriminado = 0
      let impuestosInternosTotales = 0
      let ventasNetas = 0

      pedidosTyped.forEach(p => {
        const tipoFactura = (p as unknown as Record<string, unknown>).tipo_factura as string || 'ZZ'

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
          const subtotalItem = item.subtotal || (item.cantidad * item.precio_unitario)
          productoStats[id].cantidadVendida += item.cantidad
          ventasBrutas += subtotalItem

          // Ingreso REAL por item (mig 123): FC = neto (el IVA se remite), ZZ =
          // precio final. Snapshot en ingreso_real_unitario; fallback por tipo
          // para filas legacy.
          const itemRec = item as Record<string, unknown>
          const realUnit = itemRec.ingreso_real_unitario as number | null | undefined
          if (realUnit != null) {
            productoStats[id].ingresos += realUnit * item.cantidad
            ivaDiscriminado += ((itemRec.iva_unitario as number) || 0) * item.cantidad
            impuestosInternosTotales += ((itemRec.impuestos_internos_unitario as number) || 0) * item.cantidad
            ventasNetas += ((itemRec.neto_unitario as number) ?? realUnit) * item.cantidad
          } else if (tipoFactura === 'FC' && itemRec.neto_unitario != null) {
            const netoItem = (itemRec.neto_unitario as number) * item.cantidad
            productoStats[id].ingresos += netoItem
            ivaDiscriminado += ((itemRec.iva_unitario as number) || 0) * item.cantidad
            ventasNetas += netoItem
          } else {
            // ZZ o legacy sin desglose: real = final
            productoStats[id].ingresos += subtotalItem
            ventasNetas += subtotalItem
          }

          // Costo canónico (mig 130): el mismo COALESCE que el reporte
          // gerencial. Antes se salteaba costo_promedio y cobraba el costo de
          // reposición como CMV, así que esta pestaña y el gerencial daban
          // márgenes distintos para el mismo período.
          const costoUnitario = costoCanonicoUnitario(
            (item as Record<string, unknown>).costo_unitario_al_crear as number | null,
            prod
          )
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
        margenPorcentaje: 0,
        ventasBrutas,
        ivaDiscriminado,
        impuestosInternos: impuestosInternosTotales,
        ventasNetas
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
          margenPorcentaje: 0,
          ventasBrutas: 0,
          ivaDiscriminado: 0,
          impuestosInternos: 0,
          ventasNetas: 0
        }
      }
    } finally {
      setLoading(false)
    }
  }


  return {
    loading,
    generarReporteCuentasPorCobrar,
    generarReporteRentabilidad
  }
}

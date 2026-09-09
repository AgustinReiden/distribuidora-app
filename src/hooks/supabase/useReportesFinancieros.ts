/**
 * Reportes financieros: cuentas por cobrar y rentabilidad.
 *
 * Los dos son wrappers finos sobre RPCs (mig 208): la agregación la hace la
 * base y acá sólo se desempaqueta el JSON. Antes este archivo bajaba miles de
 * filas para sumarlas en el navegador, que era a la vez incorrecto —PostgREST
 * cortaba en 1.000 sin avisar— y caro.
 */
import { useState } from 'react'
import { supabase, notifyError } from './base'
import type {
  ReporteCuentaPorCobrar,
  ReporteRentabilidad,
  UseReportesFinancierosReturn,
} from '../../types'

export function useReportesFinancieros(): UseReportesFinancierosReturn {
  const [loading, setLoading] = useState<boolean>(false)

  /**
   * Cuentas por cobrar. La agregación la hace la BASE (mig 208): devuelve una
   * fila por cliente CON saldo —111 hoy— en vez de bajar los 720 clientes y
   * todos sus pedidos impagos para sumarlos acá.
   *
   * El saldo se deriva pedido por pedido (`total - monto_pagado`) y por
   * construcción es la suma de sus tramos de aging. El RPC devuelve además el
   * `saldo_cuenta` que mantiene el trigger y un bloque `consistencia`: si algún
   * día los dos dejan de coincidir, el reporte lo dice en vez de que dos
   * pantallas muestren números distintos y nadie sepa cuál creer.
   */
  const generarReporteCuentasPorCobrar = async (): Promise<ReporteCuentaPorCobrar[]> => {
    setLoading(true)
    try {
      const { data, error } = await supabase.rpc('reporte_cuentas_por_cobrar', {
        p_sucursal_id: null,
      })
      if (error) throw error

      const res = data as {
        clientes?: unknown[]
        consistencia?: { clientes_con_desvio?: unknown[] }
      } | null

      const desvios = res?.consistencia?.clientes_con_desvio ?? []
      if (desvios.length > 0) {
        // No se rompe el reporte por esto —los números siguen siendo los
        // derivados de los pedidos— pero tiene que verse.
        notifyError(
          `Atención: ${desvios.length} cliente(s) tienen el saldo denormalizado ` +
          `distinto del calculado. El reporte usa el calculado.`
        )
      }

      return (res?.clientes ?? []) as ReporteCuentaPorCobrar[]
    } catch (error) {
      notifyError('Error al generar reporte: ' + (error as Error).message)
      return []
    } finally {
      setLoading(false)
    }
  }

  /**
   * Rentabilidad por producto, también agregada en la base (mig 208). Antes
   * bajaba los pedidos del período con sus items y sus productos embebidos, que
   * era el payload más pesado de todos los reportes.
   *
   * La cascada de costo y el ingreso real fiscal viven ahora en SQL, con la
   * misma definición que `reporte_gerencial` (migs 130 y 123).
   */
  const generarReporteRentabilidad = async (
    fechaDesde: string | null = null,
    fechaHasta: string | null = null
  ): Promise<ReporteRentabilidad> => {
    setLoading(true)
    try {
      const { data, error } = await supabase.rpc('reporte_rentabilidad', {
        p_desde: fechaDesde,
        p_hasta: fechaHasta,
        p_sucursal_id: null,
      })
      if (error) throw error
      const res = data as ReporteRentabilidad | null
      return {
        productos: res?.productos ?? [],
        totales: res?.totales ?? ({} as ReporteRentabilidad['totales']),
      }
    } catch (error) {
      notifyError('Error al generar reporte: ' + (error as Error).message)
      return { productos: [], totales: {} as ReporteRentabilidad['totales'] }
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

/**
 * TanStack Query hooks para los Reportes Gerenciales.
 *
 * Los datos salen del RPC `reporte_gerencial(sucursal, desde, hasta)` (mig 095),
 * que devuelve TODO el dashboard en un JSONB. p_sucursal_id NULL = consolidado
 * de red. El análisis narrativo mensual vive en la tabla `reportes_mensuales`
 * (lo escribe Claude Code vía el comando /reporte-mensual).
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'

export interface ReporteKpis {
  venta: number
  pedidos: number
  clientes: number
  ticket: number
  clientes_nuevos: number
  cmv: number
  bonif: number
  unidades: number
  unidades_bonif: number
  margen_comercial: number
  margen_neto: number
  base_comision: number
  comision_pct_default: number
  mermas: number
  compras: number
  ingreso_sin_costo: number
}

export interface ReporteMes {
  mes: string
  pedidos: number
  venta: number
  clientes: number
  ticket: number
  cmv: number
  bonif: number
  mermas: number
  compras: number
}

export interface ReporteVendedor {
  nombre: string
  rol: string
  pedidos: number
  venta: number
  margen_comercial: number
  bonif: number
  base_nc: number
}

export interface ReporteCategoria {
  categoria: string
  venta: number
  margen_comercial: number
  bonif: number
  sin_costo: boolean
}

export interface ReporteProducto {
  nombre: string
  unidades: number
  venta: number
  margen: number
}

export interface ReporteCliente {
  cliente: string
  pedidos: number
  venta: number
}

export interface ReporteCobranza {
  formas: { forma_pago: string; monto: number }[]
  cobrado: number
  pendiente: number
}

export interface ReporteGerencial {
  meta: {
    sucursal_id: number | null
    sucursal_nombre: string
    desde: string
    hasta: string
    generado_at: string
  }
  kpis: ReporteKpis
  mensual: ReporteMes[]
  vendedores: ReporteVendedor[]
  categorias: ReporteCategoria[]
  top_productos: ReporteProducto[]
  top_clientes: ReporteCliente[]
  cobranza: ReporteCobranza
  serie_diaria: [string, number][]
  flags: { ingreso_sin_costo: number; pct_sin_costo: number }
}

export interface AnalisisMensual {
  sucursal_id: number | null
  periodo: string
  analisis_md: string | null
  generado_por: string | null
  generado_at: string | null
}

export const reporteGerencialKeys = {
  all: ['reporte-gerencial'] as const,
  range: (suc: number | null, desde: string, hasta: string) =>
    ['reporte-gerencial', suc, desde, hasta] as const,
  analisis: (suc: number | null, periodo: string | null) =>
    ['reporte-gerencial-analisis', suc, periodo] as const,
}

/** Datos en vivo del dashboard. sucursalId null = consolidado de red. */
export function useReporteGerencialQuery(
  sucursalId: number | null,
  desde: string,
  hasta: string,
  enabled = true,
) {
  return useQuery({
    queryKey: reporteGerencialKeys.range(sucursalId, desde, hasta),
    queryFn: async (): Promise<ReporteGerencial> => {
      const { data, error } = await supabase.rpc('reporte_gerencial', {
        p_sucursal_id: sucursalId,
        p_desde: desde,
        p_hasta: hasta,
      })
      if (error) throw new Error(error.message)
      return data as ReporteGerencial
    },
    enabled,
    staleTime: 5 * 60 * 1000,
  })
}

/** Análisis narrativo guardado para un mes (escrito por Claude Code). */
export function useAnalisisMensualQuery(
  sucursalId: number | null,
  periodo: string | null,
  enabled = true,
) {
  return useQuery({
    queryKey: reporteGerencialKeys.analisis(sucursalId, periodo),
    queryFn: async (): Promise<AnalisisMensual | null> => {
      let q = supabase
        .from('reportes_mensuales')
        .select('sucursal_id, periodo, analisis_md, generado_por, generado_at')
        .eq('periodo', periodo as string)
      q = sucursalId == null ? q.is('sucursal_id', null) : q.eq('sucursal_id', sucursalId)
      const { data, error } = await q.maybeSingle()
      if (error) throw new Error(error.message)
      return (data as AnalisisMensual | null) ?? null
    },
    enabled: enabled && !!periodo,
    staleTime: 5 * 60 * 1000,
  })
}

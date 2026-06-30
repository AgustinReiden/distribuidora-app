/**
 * TanStack Query hooks para los Reportes Gerenciales.
 *
 * Los datos salen del RPC `reporte_gerencial(sucursal, desde, hasta)` (mig 095),
 * que devuelve TODO el dashboard en un JSONB. p_sucursal_id NULL = consolidado
 * de red. El análisis narrativo mensual vive en la tabla `reportes_mensuales`
 * (lo escribe Claude Code vía el comando /reporte-mensual).
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
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

export interface Alerta {
  severidad: 'critical' | 'warning' | 'info'
  codigo: string
  titulo: string
  detalle: string
  valor: number
  seccion: string
}

export interface ReporteGerencial {
  meta: {
    sucursal_id: number | null
    sucursal_nombre: string
    desde: string
    hasta: string
    generado_at: string
    incluye_no_entregados?: boolean
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
  // KPIs del período anterior (cuando se pide comparar) + alertas, ambos del RPC.
  comparativo?: (ReporteKpis & { desde: string; hasta: string }) | null
  alertas?: Alerta[]
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
  range: (suc: number | null, desde: string, hasta: string, incluirNoEntregados: boolean, comparar: boolean) =>
    ['reporte-gerencial', suc, desde, hasta, incluirNoEntregados, comparar] as const,
  analisis: (suc: number | null, periodo: string | null) =>
    ['reporte-gerencial-analisis', suc, periodo] as const,
}

/** Datos en vivo del dashboard. sucursalId null = consolidado de red. */
export function useReporteGerencialQuery(
  sucursalId: number | null,
  desde: string,
  hasta: string,
  incluirNoEntregados = false,
  comparar = false,
  enabled = true,
) {
  return useQuery({
    queryKey: reporteGerencialKeys.range(sucursalId, desde, hasta, incluirNoEntregados, comparar),
    queryFn: async (): Promise<ReporteGerencial> => {
      const { data, error } = await supabase.rpc('reporte_gerencial', {
        p_sucursal_id: sucursalId,
        p_desde: desde,
        p_hasta: hasta,
        p_incluir_no_entregados: incluirNoEntregados,
        p_comparar: comparar,
      })
      if (error) throw new Error(error.message)
      return data as ReporteGerencial
    },
    enabled,
    staleTime: 5 * 60 * 1000,
  })
}

export interface MetasGerenciales {
  venta: number | null
  margen_neto: number | null
}

export interface AlertaDetalleItem {
  nombre: string
  valor: number
  detalle: string
}

/** Lista detrás de una alerta (lazy: solo al hacer click). codigo = alerta.codigo. */
export function useAlertaDetalleQuery(
  sucursalId: number | null,
  codigo: string | null,
  enabled = true,
) {
  return useQuery({
    queryKey: ['alerta-detalle', sucursalId, codigo] as const,
    queryFn: async (): Promise<AlertaDetalleItem[]> => {
      const { data, error } = await supabase.rpc('reporte_alerta_detalle', {
        p_sucursal_id: sucursalId,
        p_codigo: codigo,
      })
      if (error) throw new Error(error.message)
      return (data as AlertaDetalleItem[] | null) ?? []
    },
    enabled: enabled && !!codigo,
    staleTime: 5 * 60 * 1000,
  })
}

/** Metas (objetivos) del mes para una sucursal (null = red). Sólo aplica a meses. */
export function useMetasGerencialQuery(
  sucursalId: number | null,
  periodoMes: string | null,
  enabled = true,
) {
  return useQuery({
    queryKey: ['metas-gerenciales', sucursalId, periodoMes] as const,
    queryFn: async (): Promise<MetasGerenciales> => {
      let q = supabase.from('metas_gerenciales').select('metrica, valor').eq('periodo', periodoMes as string)
      q = sucursalId == null ? q.is('sucursal_id', null) : q.eq('sucursal_id', sucursalId)
      const { data, error } = await q
      if (error) throw new Error(error.message)
      const rows = (data as { metrica: string; valor: number }[] | null) ?? []
      return {
        venta: rows.find((r) => r.metrica === 'venta')?.valor ?? null,
        margen_neto: rows.find((r) => r.metrica === 'margen_neto')?.valor ?? null,
      }
    },
    enabled: enabled && !!periodoMes,
    staleTime: 5 * 60 * 1000,
  })
}

/** Upsert de una meta mensual (admin). Invalida metas tras guardar. */
export function useGuardarMetaMutation() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (vars: { sucursalId: number | null; periodo: string; metrica: 'venta' | 'margen_neto'; valor: number }) => {
      const { error } = await supabase.rpc('guardar_meta_gerencial', {
        p_sucursal_id: vars.sucursalId,
        p_periodo: vars.periodo,
        p_metrica: vars.metrica,
        p_valor: vars.valor,
      })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['metas-gerenciales'] })
    },
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

/**
 * TanStack Query hooks para los Reportes Gerenciales.
 *
 * Los datos salen del RPC `reporte_gerencial(sucursal, desde, hasta, ...)`
 * (mig 095, última reescritura 110: cobranza real desde `pagos`, split de
 * mermas y `bonif_promos`), que devuelve TODO el dashboard en un JSONB.
 * p_sucursal_id NULL = consolidado de red. El análisis narrativo mensual vive
 * en la tabla `reportes_mensuales` (lo escribe Claude Code vía /reporte-mensual).
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
  /** Total operativo (la contribución resta este número). */
  mermas: number
  /** Split del total (mig 110): perdida+ajuste+muestra = mermas.
   *  Opcionales por compat con respuestas cacheadas pre-110. */
  mermas_perdida?: number
  mermas_ajuste?: number
  mermas_muestra?: number
  compras: number
  ingreso_sin_costo: number
  /** Fiscal (mig 120, opcionales por compat con respuestas cacheadas):
   *  venta_neta = Σ total_neto (ZZ: total; FC: sin IVA/II) — margen comparable
   *  entre canales; iva_debito = Σ total_iva de ventas FC. */
  venta_neta?: number
  iva_debito?: number
  margen_comercial_neto?: number
  /** Terna real (mig 124): venta_real = Σ total_real (FC: neto · ZZ: final).
   *  margen_real = venta_real − cmv es LA métrica del negocio. */
  venta_real?: number
  margen_real?: number
  margen_real_neto?: number
  fc_venta?: number
  fc_pedidos?: number
  zz_venta?: number
  zz_pedidos?: number
}

/** Resultado del RPC posicion_fiscal (mig 121). Estimación de gestión. */
export interface PosicionFiscal {
  meta: {
    sucursal_id: number | null
    sucursal_nombre: string
    desde: string
    hasta: string
    generado_at: string
    nota: string
  }
  ventas: {
    fc_pedidos: number
    fc_venta: number
    fc_neto: number
    iva_debito: number
    ii_ventas_fc: number
    zz_pedidos: number
    zz_venta: number
    pct_fc: number
  }
  compras: {
    fc_compras: number
    fc_total: number
    fc_neto: number
    iva_credito: number
    ii_compras: number
    percepcion_iva: number
    percepcion_iibb: number
    zz_compras: number
    zz_total: number
    pct_fc: number
  }
  posicion: {
    /** iva_debito − iva_credito − percepcion_iva. Positivo = IVA a pagar estimado. */
    saldo_tecnico: number
    iva_debito: number
    iva_credito: number
    percepciones_a_favor: number
  }
}

/** Fila de mermas por motivo, con clasificación de negocio (mig 110). */
export interface MermaMotivo {
  motivo: string
  unidades: number
  costo: number
  clasificacion: 'perdida' | 'ajuste' | 'muestra'
}

/** Lo regalado por promoción × producto (mig 110). */
export interface BonifPromo {
  promocion: string
  producto: string
  /** BOTELLAS si es_fraccion, fardos si no. */
  unidades: number
  es_fraccion: boolean
  /** Costo real (misma convención que kpis.bonif). */
  costo: number
  /** Valuado a precio de lista actual (÷ unidades_por_bloque si fracción). */
  valor_venta: number
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
  /** Cobros REALES (tabla pagos) de los pedidos del período, por forma (mig 110). */
  formas: { forma_pago: string; monto: number }[]
  /** Σ LEAST(monto_pagado, total): un pago parcial cuenta lo pagado. */
  cobrado: number
  /** Σ GREATEST(total − monto_pagado, 0). */
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
  // Detalle de mermas y de bonificaciones por promo (mig 110; opcionales por
  // compat con respuestas cacheadas del RPC anterior).
  mermas_motivo?: MermaMotivo[]
  bonif_promos?: BonifPromo[]
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

/** Posición fiscal del período (mig 121). sucursalId null = red. */
export function usePosicionFiscalQuery(
  sucursalId: number | null,
  desde: string,
  hasta: string,
  enabled = true,
) {
  return useQuery({
    queryKey: ['posicion-fiscal', sucursalId, desde, hasta] as const,
    queryFn: async (): Promise<PosicionFiscal> => {
      const { data, error } = await supabase.rpc('posicion_fiscal', {
        p_sucursal_id: sucursalId,
        p_desde: desde,
        p_hasta: hasta,
      })
      if (error) throw new Error(error.message)
      return data as PosicionFiscal
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

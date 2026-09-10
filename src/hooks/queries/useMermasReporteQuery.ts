/**
 * TanStack Query hook para el reporte de mermas (mig 226).
 *
 * RPC `reporte_mermas(p_desde, p_hasta, p_sucursal_id, p_motivo, p_limite_detalle)`.
 *
 * Dos cosas que lo distinguen del camino viejo (`useMermasQuery`, que bajaba las
 * filas crudas por PostgREST):
 *
 *  1. `p_sucursal_id NULL` consolida la RED. Por PostgREST no se podía: la
 *     policy `mt_mermas_stock_select` ata el SELECT a `current_sucursal_id()`.
 *  2. `totales` y `por_motivo` se calculan en la base sobre el período COMPLETO;
 *     sólo `detalle` está acotado. Truncar acorta la lista, nunca mueve un
 *     total — que era justo el defecto del modal.
 *
 * `totales.costo` cierra EXACTO contra `reporte_gerencial.kpis.mermas`.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import type { ClasificacionMerma, OrigenCostoMerma } from '../../utils/mermasMotivo'

/** Tope del RPC. El servidor clampea a este valor aunque se le pida más. */
export const LIMITE_DETALLE_MERMAS = 2000

export interface MermaMotivoReporte {
  motivo: string
  clasificacion: ClasificacionMerma
  registros: number
  unidades: number
  costo: number
  precio: number
  filas_costo_estimado: number
  filas_sin_costo: number
}

export interface MermaDetalle {
  /** bigint en la base: llega como number, se tipa string para no comparar por identidad. */
  id: string
  created_at: string
  cantidad: number
  motivo: string
  clasificacion: ClasificacionMerma
  costo_unitario: number | null
  costo_total: number | null
  precio_unitario: number | null
  precio_total: number | null
  origen_costo: OrigenCostoMerma
  producto_id: string
  producto_nombre: string
  producto_codigo: string | null
  producto_categoria: string | null
  stock_anterior: number
  stock_nuevo: number
  usuario_id: string | null
  usuario_nombre: string | null
  sucursal_id: string
  sucursal_nombre: string | null
  observaciones: string | null
}

export interface TotalesMermasReporte {
  registros: number
  unidades: number
  costo: number
  precio: number
  costo_perdida: number
  costo_ajuste: number
  costo_muestra: number
  /** Los ajustes de promoción quedan FUERA de `costo`: se informan aparte. */
  registros_ajuste_promocion: number
  unidades_ajuste_promocion: number
  costo_ajuste_promocion: number
  filas_costo_estimado: number
  filas_sin_costo: number
}

export interface ReporteMermas {
  meta: {
    sucursal_id: number | null
    sucursal_nombre: string
    desde: string
    hasta: string
    generado_at: string
    filtro_motivo: string | null
    criterio: string
  }
  totales: TotalesMermasReporte
  por_motivo: MermaMotivoReporte[]
  detalle: MermaDetalle[]
  detalle_total: number
  detalle_limite: number
  detalle_truncado: boolean
}

export const mermasReporteKeys = {
  all: ['reporte-mermas'] as const,
  range: (
    sucursalId: number | null,
    desde: string,
    hasta: string,
    motivo: string | null,
    limite: number,
  ) => ['reporte-mermas', sucursalId, desde, hasta, motivo, limite] as const,
}

export async function fetchReporteMermas(
  sucursalId: number | null,
  desde: string,
  hasta: string,
  motivo: string | null = null,
  limiteDetalle?: number,
): Promise<ReporteMermas> {
  const { data, error } = await supabase.rpc('reporte_mermas', {
    p_desde: desde,
    p_hasta: hasta,
    p_sucursal_id: sucursalId,
    p_motivo: motivo,
    ...(limiteDetalle != null ? { p_limite_detalle: limiteDetalle } : {}),
  })
  if (error) throw new Error(error.message)
  return data as ReporteMermas
}

export function useMermasReporteQuery(
  sucursalId: number | null,
  desde: string,
  hasta: string,
  motivo: string | null = null,
  enabled = true,
) {
  return useQuery({
    queryKey: mermasReporteKeys.range(sucursalId, desde, hasta, motivo, 0),
    queryFn: () => fetchReporteMermas(sucursalId, desde, hasta, motivo),
    enabled: enabled && Boolean(desde) && Boolean(hasta),
    staleTime: 5 * 60 * 1000,
  })
}

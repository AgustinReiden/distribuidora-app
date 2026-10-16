/**
 * Reporte de rechazos (#1198): RPC `reporte_rechazos(p_desde, p_hasta, p_sucursal_id)`.
 *
 * Junta los rechazos totales (pedidos cancelados con un motivo que no es
 * administrativo) y los parciales (salvedades vigentes), cortados por la fecha
 * del pedido. `p_sucursal_id NULL` consolida la red (activas ∩ asignadas, como
 * `reporte_mermas`). Los totales y los cortes son del período completo; sólo el
 * detalle tiene tope (`detalle_limite`).
 *
 * Muestra causas, no culpas: no hay responsable por motivo ni por rol.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import type { FilaRechazo, TipoRechazo } from '../../utils/rechazos'

export interface TotalesRechazos {
  pedidos_salieron: number
  pedidos_entregados: number
  rechazos_totales: number
  pedidos_con_salvedad: number
  lineas_salvedad: number
  salvedades_pendientes: number
  /** Todo lo rechazado, a precio de venta. */
  monto: number
  /** Lo que volvió al stock, a precio de venta. */
  venta_perdida: number
  venta_perdida_total: number
  venta_perdida_parcial: number
  /** Lo mermado, a costo (mermas_valorizadas). */
  perdida_real: number
  /** Lo mermado, a precio de venta (parte de `monto`). */
  monto_mermado: number
  /** Lo que no movió stock, a precio de venta (parte de `monto`). */
  monto_sin_movimiento: number
  /** Mermas sin costo cargado: no suman a `perdida_real`. */
  mermas_sin_costo: number
  tasa_rechazo: number | null
  tasa_rechazo_total: number | null
  tasa_con_salvedad: number | null
}

/** Los montos de cada corte. */
export interface MontosRechazo {
  monto: number
  venta_perdida: number
  perdida_real: number
}

/** Corte por preventista o por chofer: con la tasa. */
export interface CortePersonaRechazos extends MontosRechazo {
  nombre: string | null
  pedidos_salieron: number
  pedidos_entregados: number
  rechazos_totales: number
  pedidos_con_salvedad: number
  lineas_salvedad: number
  tasa_rechazo: number | null
}

export interface CortePreventista extends CortePersonaRechazos {
  usuario_id: string | null
}

export interface CorteChofer extends CortePersonaRechazos {
  transportista_id: string | null
}

export interface CorteMotivo extends MontosRechazo {
  tipo: TipoRechazo
  motivo: string
  casos: number
  unidades: number
}

export interface CorteCliente extends MontosRechazo {
  cliente_id: number | string | null
  nombre: string | null
  codigo: string | null
  /** Historial: el cliente inactivo también aparece. */
  activo: boolean | null
  rechazos_totales: number
  lineas_salvedad: number
}

export interface CorteProducto extends MontosRechazo {
  producto_id: number | string | null
  nombre: string | null
  codigo: string | null
  unidades_total: number
  unidades_parcial: number
  lineas_salvedad: number
}

export interface ReporteRechazos {
  meta: {
    sucursal_id: number | null
    sucursal_nombre: string
    desde: string
    hasta: string
    generado_at: string
    motivos_administrativos: string[]
    criterio: string
  }
  totales: TotalesRechazos
  por_motivo: CorteMotivo[]
  por_preventista: CortePreventista[]
  por_chofer: CorteChofer[]
  por_cliente: CorteCliente[]
  por_producto: CorteProducto[]
  detalle: FilaRechazo[]
  detalle_total: number
  detalle_limite: number
  detalle_truncado: boolean
}

export const rechazosReporteKeys = {
  all: ['reporte-rechazos'] as const,
  range: (sucursalId: number | null, desde: string, hasta: string) =>
    ['reporte-rechazos', sucursalId, desde, hasta] as const,
}

export async function fetchReporteRechazos(
  sucursalId: number | null,
  desde: string,
  hasta: string,
): Promise<ReporteRechazos> {
  const { data, error } = await supabase.rpc('reporte_rechazos', {
    p_desde: desde,
    p_hasta: hasta,
    p_sucursal_id: sucursalId,
  })
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar el reporte de rechazos. Revisá la señal e intentá de nuevo.')
  return data as ReporteRechazos
}

export function useRechazosReporteQuery(
  sucursalId: number | null,
  desde: string,
  hasta: string,
  enabled = true,
) {
  return useQuery({
    queryKey: rechazosReporteKeys.range(sucursalId, desde, hasta),
    queryFn: () => fetchReporteRechazos(sucursalId, desde, hasta),
    enabled: enabled && Boolean(desde) && Boolean(hasta),
    staleTime: 5 * 60 * 1000,
  })
}

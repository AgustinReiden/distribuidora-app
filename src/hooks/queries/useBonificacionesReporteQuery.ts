/**
 * Reporte de bonificaciones: RPC `reporte_bonificaciones(p_desde, p_hasta,
 * p_sucursal_id, p_limite_detalle)`.
 *
 * Lo regalado por promoción en los pedidos ENTREGADOS del período, por fecha del
 * pedido, con el criterio del gerencial: `totales.costo` cierra exacto contra
 * `kpis.bonif` y `totales.venta` contra `kpis.venta` (lo verifica el ensayo de la
 * migración). No es la merma "Promociones": esa es la salida de stock del regalo,
 * por día de carga, y cuenta también lo que todavía no se entregó.
 *
 * Los totales y los cortes son del período completo; sólo el detalle tiene tope
 * (`detalle_limite`).
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { errorDeSupabase } from '../../utils/errorDeSupabase'

/** Tope del detalle que se pide: el servidor clampea a 5000. */
export const LIMITE_DETALLE_BONIFICACIONES = 5000

/** Los montos de cualquier corte. `bultos` es la cantidad en bultos: una
 *  botella de un fardo de 6 es 1/6. `unidades` mezcla botellas y bultos. */
export interface MontosBonificacion {
  bultos: number
  costo: number
  /** A precio de lista de hoy. */
  valor_venta: number
}

export interface TotalesBonificaciones extends MontosBonificacion {
  lineas: number
  pedidos_con_bonif: number
  clientes_con_bonif: number
  pedidos_entregados: number
  unidades: number
  /** Venta de productos de todos los pedidos entregados del período. */
  venta: number
  /** Venta de productos de los pedidos que llevaron regalo. */
  venta_pedidos_con_bonif: number
  filas_sin_costo: number
}

export interface BonifPorPromocion extends MontosBonificacion {
  promocion_id: number | null
  nombre: string
  activo: boolean | null
  fecha_inicio: string | null
  fecha_fin: string | null
  pedidos: number
  clientes: number
  unidades: number
  filas_sin_costo: number
}

export interface BonifPorProducto extends MontosBonificacion {
  producto_id: number | null
  nombre: string
  codigo: string | null
  es_fraccion: boolean
  pedidos: number
  unidades: number
  filas_sin_costo: number
}

export interface BonifPorPromocionProducto extends MontosBonificacion {
  promocion_id: number | null
  promocion: string
  producto_id: number | null
  producto: string
  es_fraccion: boolean
  unidades: number
}

/** Vendedor o cliente: trae su venta del período para leer el regalo contra ella. */
export interface BonifPorVendedor extends MontosBonificacion {
  usuario_id: string | null
  nombre: string
  pedidos_entregados: number
  pedidos_con_bonif: number
  venta: number
}

export interface BonifPorCliente extends MontosBonificacion {
  cliente_id: number | null
  nombre: string | null
  codigo: string | null
  activo: boolean | null
  pedidos_entregados: number
  pedidos_con_bonif: number
  venta: number
}

export interface LineaBonificacion extends MontosBonificacion {
  pedido_id: number
  fecha: string
  sucursal_nombre: string | null
  cliente_id: number | null
  cliente_nombre: string | null
  cliente_activo: boolean | null
  usuario_id: string | null
  vendedor_nombre: string
  promocion_id: number | null
  promocion_nombre: string
  producto_id: number | null
  producto_nombre: string
  producto_codigo: string | null
  cantidad: number
  es_fraccion: boolean
  factor: number
  /** Costo de una unidad de la línea (la botella, si es fracción). Null = sin costo. */
  costo_unitario: number | null
  sin_costo: boolean
}

export interface ReporteBonificaciones {
  meta: {
    sucursal_id: number | null
    sucursal_nombre: string
    desde: string
    hasta: string
    generado_at: string
    criterio: string
  }
  totales: TotalesBonificaciones
  por_promocion: BonifPorPromocion[]
  por_producto: BonifPorProducto[]
  por_promocion_producto: BonifPorPromocionProducto[]
  por_vendedor: BonifPorVendedor[]
  por_cliente: BonifPorCliente[]
  detalle: LineaBonificacion[]
  detalle_total: number
  detalle_limite: number
  detalle_truncado: boolean
}

export const bonificacionesReporteKeys = {
  all: ['reporte-bonificaciones'] as const,
  range: (sucursalId: number | null, desde: string, hasta: string) =>
    ['reporte-bonificaciones', sucursalId, desde, hasta] as const,
}

export async function fetchReporteBonificaciones(
  sucursalId: number | null,
  desde: string,
  hasta: string,
): Promise<ReporteBonificaciones> {
  const { data, error } = await supabase.rpc('reporte_bonificaciones', {
    p_desde: desde,
    p_hasta: hasta,
    p_sucursal_id: sucursalId,
    p_limite_detalle: LIMITE_DETALLE_BONIFICACIONES,
  })
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar el reporte de bonificaciones. Revisá la señal e intentá de nuevo.')
  return data as ReporteBonificaciones
}

export function useBonificacionesReporteQuery(
  sucursalId: number | null,
  desde: string,
  hasta: string,
  enabled = true,
) {
  return useQuery({
    queryKey: bonificacionesReporteKeys.range(sucursalId, desde, hasta),
    queryFn: () => fetchReporteBonificaciones(sucursalId, desde, hasta),
    enabled: enabled && Boolean(desde) && Boolean(hasta),
    staleTime: 5 * 60 * 1000,
  })
}

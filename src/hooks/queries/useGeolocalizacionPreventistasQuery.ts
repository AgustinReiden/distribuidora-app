/**
 * useGeolocalizacionPreventistasQuery
 *
 * Hook que consume la RPC `obtener_geolocalizacion_preventistas`. Devuelve
 * el shape consolidado del panel admin "Geolocalización": resumen por
 * preventista + detalle de pedidos con coordenadas y distancia al cliente.
 *
 * - RPC: scope a `current_sucursal_id()`, solo admin.
 * - Auto-refresh cada 60 s cuando el rango incluye HOY (regla en el caller
 *   vía el flag `autoRefresh`).
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'

export type GpsStatus = 'ok' | 'denied' | 'unavailable' | 'timeout' | 'error'

export interface UltimaUbicacion {
  lat: number
  lng: number
  capturado_at: string
  pedido_id: number
}

export interface PreventistaResumen {
  preventista_id: string
  preventista_nombre: string
  total_pedidos: number
  pedidos_con_gps: number
  pedidos_sin_gps: number
  pedidos_lejos: number
  ultima_ubicacion: UltimaUbicacion | null
}

export interface PedidoConGps {
  pedido_id: number
  preventista_id: string
  fecha: string
  /**
   * Timestamp ISO en que se creó el pedido (`pedidos.created_at`). Se usa
   * para mostrar la hora de creación en el panel admin. Disponible a partir
   * de la migración 041; antes de eso el RPC no lo devolvía y queda null.
   */
  pedido_created_at: string | null
  total: number
  gps_lat: number | null
  gps_lng: number | null
  gps_accuracy: number | null
  gps_capturado_at: string | null
  gps_status: GpsStatus | null
  cliente_id: number | null
  cliente_nombre: string | null
  cliente_lat: number | null
  cliente_lng: number | null
  distancia_m: number | null
}

export interface GeolocalizacionPanelData {
  fecha_desde: string
  fecha_hasta: string
  preventistas: PreventistaResumen[]
  pedidos: PedidoConGps[]
}

const EMPTY: GeolocalizacionPanelData = {
  fecha_desde: '',
  fecha_hasta: '',
  preventistas: [],
  pedidos: [],
}

async function fetchGeolocalizacion(
  fechaDesde: string,
  fechaHasta: string,
): Promise<GeolocalizacionPanelData> {
  const { data, error } = await supabase.rpc('obtener_geolocalizacion_preventistas', {
    p_fecha_desde: fechaDesde,
    p_fecha_hasta: fechaHasta,
  })
  if (error) throw error
  return (data as GeolocalizacionPanelData) ?? EMPTY
}

export const geolocalizacionKeys = {
  all: (sucursalId: number | null) => ['geolocalizacion', 'preventistas', sucursalId] as const,
  range: (sucursalId: number | null, desde: string, hasta: string) =>
    ['geolocalizacion', 'preventistas', sucursalId, desde, hasta] as const,
}

export function useGeolocalizacionPreventistasQuery(
  fechaDesde: string,
  fechaHasta: string,
  options: { enabled?: boolean; autoRefresh?: boolean } = {},
) {
  const { currentSucursalId } = useSucursal()
  const { enabled = true, autoRefresh = false } = options

  return useQuery({
    queryKey: geolocalizacionKeys.range(currentSucursalId, fechaDesde, fechaHasta),
    queryFn: () => fetchGeolocalizacion(fechaDesde, fechaHasta),
    enabled: enabled && !!fechaDesde && !!fechaHasta,
    refetchInterval: autoRefresh ? 60_000 : false,
    staleTime: autoRefresh ? 0 : 30_000,
  })
}

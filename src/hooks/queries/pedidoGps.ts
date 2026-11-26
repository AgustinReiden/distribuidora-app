/**
 * El check-in GPS de los pedidos (permisos-B4, decisión del dueño D10; mig NNN_ola3_t8b_pedido_gps).
 *
 * El GPS del preventista ya no viene en la fila de `pedidos`, que el chofer lee: vive en
 * `pedido_gps`, una fila por pedido con check-in, que por RLS lee sólo el admin de la sucursal
 * activa. Al resto la tabla le da cero filas, así que el hook se apaga para quien no es admin
 * (no gasta la consulta). Sin fila = el pedido no tiene check-in.
 *
 * El chip es un extra: un error (sin señal, la tabla que todavía no existe) se tira y la tarjeta
 * sale igual, sin el chip.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useSucursal } from '../../contexts/SucursalContext'
import type { PedidoGps } from '../../types'

/** Lo que dibuja el chip de la tarjeta; no se pide más (ni la precisión ni el diagnóstico). */
export const PEDIDO_GPS_COLUMNAS = 'pedido_id, gps_status, gps_lat, gps_lng'

/** De a cuántos ids se pide: la lista va en la URL (`in.(…)`). */
const TANDA = 200

const SIN_CONEXION = 'Sin conexión: no se pudo cargar el GPS de los pedidos. Revisá la señal e intentá de nuevo.'

function idsUnicos(ids: Array<string | number>): string[] {
  return [...new Set(ids.map(String).filter(id => id !== '' && id !== 'undefined' && id !== 'null'))].sort()
}

export async function fetchPedidosGps(ids: Array<string | number>): Promise<Map<string, PedidoGps>> {
  const unicos = idsUnicos(ids)
  const mapa = new Map<string, PedidoGps>()
  for (let i = 0; i < unicos.length; i += TANDA) {
    const tanda = unicos.slice(i, i + TANDA)
    const { data, error } = await supabase
      .from('pedido_gps')
      .select(PEDIDO_GPS_COLUMNAS)
      .in('pedido_id', tanda)
    if (error) throw errorDeSupabase(error, SIN_CONEXION)
    for (const fila of (data as PedidoGps[] | null) ?? []) {
      if (fila?.pedido_id != null) mapa.set(String(fila.pedido_id), fila)
    }
  }
  return mapa
}

/** El GPS de esos pedidos, por id (texto). Sólo para el admin: al resto la RLS le da nada. */
export function usePedidosGpsQuery(ids: Array<string | number>, opciones: { enabled?: boolean } = {}) {
  const { currentSucursalId } = useSucursal()
  const unicos = idsUnicos(ids)
  const { enabled = true } = opciones
  return useQuery({
    queryKey: ['pedidos', 'gps', currentSucursalId, unicos] as const,
    queryFn: () => fetchPedidosGps(unicos),
    enabled: enabled && unicos.length > 0,
    staleTime: 60 * 1000,
  })
}

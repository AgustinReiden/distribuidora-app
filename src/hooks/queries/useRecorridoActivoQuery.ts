/**
 * Recorrido vigente (en_curso) de hoy del transportista logueado.
 *
 * Lo usa la pantalla Ruta Activa SOLO para obtener las `polylines` (la ruta
 * real sobre las calles que guardó el admin al aplicar el orden) y dibujarla.
 * Las paradas y el flujo de entrega NO dependen de esto: se arman desde
 * `pedidos.orden_entrega`. Si no hay recorrido (o es viejo sin polyline), el
 * mapa cae al trazado recto — degradado seguro.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { fechaLocalISO } from '../../utils/formatters'

export interface RecorridoActivo {
  id: string
  polylines: string[] | null
}

export const recorridoActivoKeys = {
  all: (sucursalId: number | null, transportistaId: string | null) =>
    ['recorrido-activo', sucursalId, transportistaId] as const,
}

async function fetchRecorridoActivo(transportistaId: string): Promise<RecorridoActivo | null> {
  const { data, error } = await supabase
    .from('recorridos')
    .select('id, polylines')
    .eq('transportista_id', transportistaId)
    .eq('fecha', fechaLocalISO())
    .eq('estado', 'en_curso')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle()

  if (error) throw error
  if (!data) return null
  return { id: String(data.id), polylines: (data.polylines as string[] | null) ?? null }
}

export function useRecorridoActivoQuery(transportistaId: string | null | undefined) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: recorridoActivoKeys.all(currentSucursalId, transportistaId ?? null),
    queryFn: () => fetchRecorridoActivo(transportistaId as string),
    enabled: !!transportistaId,
    staleTime: 2 * 60 * 1000,
  })
}

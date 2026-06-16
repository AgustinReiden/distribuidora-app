/**
 * Recorrido vigente (en_curso) de un transportista para una fecha dada, CON sus
 * paradas enriquecidas (mismo shape que el pool de la ruta). Lo usa el admin en
 * "Armar ruta del día" para EDITAR una ruta ya armada: precarga sus paradas
 * (pre-tildadas) y las fusiona con los pedidos disponibles.
 *
 * A diferencia de useRecorridoActivoQuery (transportista logueado, hoy), acá la
 * fecha y el transportista los elige el admin. Reutiliza PEDIDO_SELECT para que
 * cada parada tenga exactamente la misma forma que un pedido del pool (necesario
 * para optimizar y generar la hoja de ruta).
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { PEDIDO_SELECT } from './usePedidosQuery'
import type { PedidoDB } from '../../types'

export interface RecorridoExistente {
  recorridoId: string
  /** Pedidos de la ruta, ordenados por orden_entrega. */
  paradas: PedidoDB[]
}

export const recorridoExistenteKeys = {
  all: (sucursalId: number | null, transportistaId: string | null, fecha: string | null) =>
    ['recorrido-existente', sucursalId, transportistaId, fecha] as const,
}

const SELECT = `id,
  recorrido_pedidos(
    orden_entrega,
    pedido:pedidos(${PEDIDO_SELECT})
  )`

interface RecorridoExistenteRaw {
  id: number | string
  recorrido_pedidos?: Array<{
    orden_entrega: number | null
    pedido: (Record<string, unknown> & { orden_entrega?: number | null }) | null
  }>
}

async function fetchRecorridoExistente(
  sucursalId: number | null,
  transportistaId: string,
  fecha: string,
): Promise<RecorridoExistente | null> {
  let query = supabase
    .from('recorridos')
    .select(SELECT)
    .eq('transportista_id', transportistaId)
    .eq('fecha', fecha)
    .eq('estado', 'en_curso')
    .order('created_at', { ascending: false })
    .limit(1)

  if (sucursalId != null) query = query.eq('sucursal_id', sucursalId)

  const { data, error } = await query.maybeSingle()
  if (error) throw error
  if (!data) return null

  const raw = data as unknown as RecorridoExistenteRaw
  const paradas = (raw.recorrido_pedidos || [])
    .filter(rp => rp.pedido != null)
    // El orden de entrega del recorrido es la fuente de verdad.
    .sort((a, b) => (a.orden_entrega ?? 999) - (b.orden_entrega ?? 999))
    .map(rp => ({
      ...(rp.pedido as object),
      orden_entrega: rp.orden_entrega ?? rp.pedido?.orden_entrega ?? null,
    })) as unknown as PedidoDB[]

  return { recorridoId: String(raw.id), paradas }
}

export function useRecorridoExistenteQuery(
  transportistaId: string | null | undefined,
  fecha: string | null | undefined,
) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: recorridoExistenteKeys.all(currentSucursalId, transportistaId ?? null, fecha ?? null),
    queryFn: () => fetchRecorridoExistente(currentSucursalId, transportistaId as string, fecha as string),
    enabled: !!transportistaId && !!fecha,
    staleTime: 30 * 1000,
  })
}

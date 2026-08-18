/**
 * Rutas ya armadas (en_curso) de un transportista, de hoy en adelante.
 *
 * `useRecorridoExistenteQuery` responde "¿hay ruta para ESTA fecha?" y con eso
 * el modal precarga las paradas. El problema es la respuesta negativa: si la
 * ruta existe en OTRA fecha, la pantalla no dice nada y parece que armar de
 * nuevo no estuviera permitido.
 *
 * Caso real (2026-08-02): la ruta se armó el 01/08 para el 02/08. Al día
 * siguiente el modal abre con la fecha de entrega en su default —mañana, 03/08—,
 * no encuentra ruta para esa fecha, y como los pedidos de la ruta del 02/08 ya
 * están en estado `asignado` (fuera del pool de disponibles), la pantalla queda
 * con un solo pedido nuevo y sin ninguna señal de que la ruta del 02/08 existe.
 *
 * Esta query es la que permite decirlo.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { fechaLocalISO } from '../../utils/formatters'

export interface RutaEnCurso {
  recorridoId: string
  fecha: string
  paradas: number
  /** Sólo lo puebla la variante multi; en la de un chofer es redundante. */
  transportistaId?: string
}

export const rutasEnCursoKeys = {
  all: (sucursalId: number | null, transportistaId: string | null) =>
    ['rutas-en-curso', sucursalId, transportistaId] as const,
  multi: (sucursalId: number | null, transportistaIds: string[]) =>
    ['rutas-en-curso', 'multi', sucursalId, [...transportistaIds].sort().join(',')] as const,
}

interface RutaEnCursoRaw {
  id: number | string
  fecha: string
  // `recorrido_pedidos` tiene una sola FK a `recorridos`, así que el embed no es
  // ambiguo (PGRST201). Verificado contra el catálogo antes de escribirlo.
  recorrido_pedidos?: Array<{ count: number }>
}

async function fetchRutasEnCurso(
  sucursalId: number | null,
  transportistaId: string,
): Promise<RutaEnCurso[]> {
  let query = supabase
    .from('recorridos')
    .select('id, fecha, recorrido_pedidos(count)')
    .eq('transportista_id', transportistaId)
    .eq('estado', 'en_curso')
    .gte('fecha', fechaLocalISO())
    .order('fecha', { ascending: true })

  if (sucursalId != null) query = query.eq('sucursal_id', sucursalId)

  const { data, error } = await query
  if (error) throw error

  return ((data as unknown as RutaEnCursoRaw[]) || []).map(r => ({
    recorridoId: String(r.id),
    fecha: r.fecha,
    paradas: r.recorrido_pedidos?.[0]?.count ?? 0,
  }))
}

export function useRutasEnCursoQuery(transportistaId: string | null | undefined) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: rutasEnCursoKeys.all(currentSucursalId, transportistaId ?? null),
    queryFn: () => fetchRutasEnCurso(currentSucursalId, transportistaId as string),
    enabled: !!transportistaId,
    staleTime: 30 * 1000,
  })
}

async function fetchRutasEnCursoMulti(
  sucursalId: number | null,
  transportistaIds: string[],
): Promise<RutaEnCurso[]> {
  let query = supabase
    .from('recorridos')
    .select('id, fecha, transportista_id, recorrido_pedidos(count)')
    .in('transportista_id', transportistaIds)
    .eq('estado', 'en_curso')
    .gte('fecha', fechaLocalISO())
    .order('fecha', { ascending: true })

  if (sucursalId != null) query = query.eq('sucursal_id', sucursalId)

  const { data, error } = await query
  if (error) throw error

  return ((data as unknown as Array<RutaEnCursoRaw & { transportista_id: string }>) || []).map(r => ({
    recorridoId: String(r.id),
    fecha: r.fecha,
    paradas: r.recorrido_pedidos?.[0]?.count ?? 0,
    transportistaId: String(r.transportista_id),
  }))
}

/**
 * Igual que la anterior pero para VARIOS choferes a la vez.
 *
 * La necesita el modo "Dividir" de armar ruta, que hasta ahora pasaba `null` a
 * la query de un chofer —o sea, la tenía apagada— y por lo tanto era ciego a las
 * rutas ya armadas. Como `aplicar_orden_ruta` reemplaza las paradas pendientes
 * del recorrido de ese día, dividir sobre un chofer que está repartiendo le
 * vacía las paradas del celular en plena calle, sin que nadie lo vea venir.
 */
export function useRutasEnCursoMultiQuery(transportistaIds: string[]) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: rutasEnCursoKeys.multi(currentSucursalId, transportistaIds),
    queryFn: () => fetchRutasEnCursoMulti(currentSucursalId, transportistaIds),
    enabled: transportistaIds.length > 0,
    staleTime: 30 * 1000,
  })
}

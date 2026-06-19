/**
 * Recorridos de una fecha (no cancelados) con sus paradas COMPLETAS, para
 * re-descargar la hoja de ruta ya armada desde Exportaciones > PDF > Hoja de
 * Ruta (elegir día + transportista). Incluye 'en_curso' y 'completado' para
 * poder bajar también rutas de días pasados.
 *
 * Reutiliza PEDIDO_SELECT para que las paradas tengan la misma forma que un
 * pedido normal y `generarHojaRutaOptimizada` reciba todos los datos (items,
 * cliente, horarios, etc.).
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { PEDIDO_SELECT } from './usePedidosQuery'
import type { PedidoDB } from '../../types'

export interface RecorridoHojaRuta {
  recorridoId: string
  transportistaId: string
  transportistaNombre: string
  /** Pedidos de la ruta, ordenados por orden_entrega. */
  paradas: PedidoDB[]
}

export const recorridosHojaRutaKeys = {
  all: (sucursalId: number | null, fecha: string | null) =>
    ['recorridos-hoja-ruta', sucursalId, fecha] as const,
}

const SELECT = `id,
  transportista:perfiles!transportista_id(id, nombre),
  recorrido_pedidos(
    orden_entrega,
    pedido:pedidos(${PEDIDO_SELECT})
  )`

interface RecorridoHojaRutaRaw {
  id: number | string
  transportista: { id: string; nombre: string } | null
  recorrido_pedidos?: Array<{
    orden_entrega: number | null
    pedido: (Record<string, unknown> & { orden_entrega?: number | null }) | null
  }>
}

async function fetchRecorridosHojaRuta(
  sucursalId: number | null,
  fecha: string,
): Promise<RecorridoHojaRuta[]> {
  let query = supabase
    .from('recorridos')
    .select(SELECT)
    .eq('fecha', fecha)
    .neq('estado', 'cancelado')
    .order('created_at', { ascending: false })

  if (sucursalId != null) query = query.eq('sucursal_id', sucursalId)

  const { data, error } = await query
  if (error) throw error

  const rows = (data || []) as unknown as RecorridoHojaRutaRaw[]
  // Un recorrido vigente por transportista (índice único parcial, mig 088), pero
  // por robustez nos quedamos con el primero (más reciente) de cada transportista.
  const vistos = new Set<string>()
  const result: RecorridoHojaRuta[] = []
  for (const r of rows) {
    const tid = r.transportista?.id
    if (!tid || vistos.has(tid)) continue
    vistos.add(tid)
    const paradas = (r.recorrido_pedidos || [])
      .filter(rp => rp.pedido != null)
      .sort((a, b) => (a.orden_entrega ?? 999) - (b.orden_entrega ?? 999))
      .map(rp => ({
        ...(rp.pedido as object),
        orden_entrega: rp.orden_entrega ?? rp.pedido?.orden_entrega ?? null,
      })) as unknown as PedidoDB[]
    result.push({
      recorridoId: String(r.id),
      transportistaId: tid,
      transportistaNombre: r.transportista?.nombre || 'Transportista',
      paradas,
    })
  }
  return result
}

export function useRecorridosHojaRutaQuery(fecha: string | null | undefined) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: recorridosHojaRutaKeys.all(currentSucursalId, fecha ?? null),
    queryFn: () => fetchRecorridosHojaRuta(currentSucursalId, fecha as string),
    enabled: !!fecha,
    // La exportacion debe reflejar SIEMPRE el ultimo precio/estado del pedido:
    // sin ventana de frescura y con refetch al abrir el modal, ademas de la
    // invalidacion de ['recorridos-hoja-ruta'] al editar items del pedido.
    staleTime: 0,
    refetchOnMount: 'always',
  })
}

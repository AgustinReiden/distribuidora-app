/**
 * Pedidos trabados: quedaron en `asignado` y envejecieron ahí.
 *
 * El agujero que tapan: el pool de "Armar ruta del día" (`fetchPedidosAsignados`)
 * filtra `estado IN ('pendiente','en_preparacion')`. Un pedido que llegó a
 * `asignado` y no se entregó ni se canceló queda fuera de ese pool PARA SIEMPRE
 * y no aparece en ninguna pantalla.
 *
 * Lo importante es que la salida SÍ existe y está cableada desde hace rato:
 * "Volver a pendiente" (`handleVolverAPendiente` en PedidosContainer) desasigna,
 * vuelve el pedido a `pendiente` y lo saca de la ruta en curso. El problema
 * nunca fue que no se pudiera — es que nadie sabía que había que hacerlo.
 * Falta el listado, no el botón.
 *
 * Al 2026-08-19 eran 21 pedidos por $632.600, el más viejo del 24/06.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { pedidosKeys } from './usePedidosQuery'

/**
 * Días que un pedido puede estar `asignado` antes de considerarse trabado.
 *
 * Con 2 días no se cuela ninguno en vuelo: el reparto normal se arma para el día
 * siguiente y se cierra ese mismo día. En producción el corte es nítido — no hay
 * ningún pedido `asignado` de entre 2 y 7 días: o son de hoy/ayer, o llevan
 * semanas.
 */
export const DIAS_PARA_CONSIDERAR_TRABADO = 2

export interface PedidoTrabado {
  id: string
  fecha: string | null
  total: number
  clienteNombre: string
  transportistaId: string | null
  /** Días enteros que lleva en `asignado`. */
  diasTrabado: number
}

function diasDesde(fecha: string | null): number {
  if (!fecha) return 0
  const d = new Date(`${fecha}T12:00:00`)
  return Math.max(0, Math.floor((Date.now() - d.getTime()) / 86_400_000))
}

async function fetchPedidosTrabados(sucursalId: number | null): Promise<PedidoTrabado[]> {
  const corte = new Date()
  corte.setDate(corte.getDate() - DIAS_PARA_CONSIDERAR_TRABADO)
  const corteISO = corte.toISOString().slice(0, 10)

  let query = supabase
    .from('pedidos')
    .select('id, fecha, total, transportista_id, cliente:clientes(nombre_fantasia, razon_social)')
    .eq('estado', 'asignado')
    .lt('fecha', corteISO)

  if (sucursalId != null) query = query.eq('sucursal_id', sucursalId)

  const { data, error } = await query.order('fecha', { ascending: true })
  if (error) throw error

  return (data || []).map(p => {
    // PostgREST devuelve el embed como objeto o array segun la relacion.
    const c = p.cliente as unknown
    const cliente = (Array.isArray(c) ? c[0] : c) as
      | { nombre_fantasia?: string; razon_social?: string }
      | null
    return {
      id: String(p.id),
      fecha: p.fecha as string | null,
      total: Number(p.total) || 0,
      clienteNombre: cliente?.nombre_fantasia || cliente?.razon_social || 'Cliente',
      transportistaId: (p.transportista_id as string | null) ?? null,
      diasTrabado: diasDesde(p.fecha as string | null),
    }
  })
}

/**
 * Solo para admin/encargado: la acción de rescate (volver a pendiente) es suya.
 * Un preventista vería únicamente los propios por RLS, pero no puede resolverlos,
 * así que mostrárselos sería ruido.
 */
export function usePedidosTrabadosQuery(enabled = false) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: [...pedidosKeys.all(currentSucursalId), 'trabados'] as const,
    queryFn: () => fetchPedidosTrabados(currentSucursalId),
    enabled,
    staleTime: 5 * 60 * 1000,
  })
}

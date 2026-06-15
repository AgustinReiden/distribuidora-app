/**
 * Recorrido vigente (en_curso) de hoy del transportista logueado, CON sus
 * paradas. Es la "ruta del día" que arma el admin: el transportista lee de
 * acá, NO de "todos sus pedidos asignados" (que colaba entregados-no-marcados
 * de días previos).
 *
 * El embedding PostgREST funciona con las RLS existentes: el transportista ve
 * su recorrido (transportista_id = auth.uid()), sus recorrido_pedidos (vía el
 * recorrido propio), sus pedidos (transportista_id = auth.uid()), los items de
 * esos pedidos y los clientes/productos de su sucursal. Sin RPC.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { fechaLocalISO } from '../../utils/formatters'
import type { PedidoConCliente } from '../../components/rutaActiva/useEntregaParada'

export interface RecorridoActivo {
  id: string
  polylines: string[] | null
  /** Paradas de la ruta del día, ordenadas por orden_entrega, enriquecidas. */
  paradas: PedidoConCliente[]
}

export const recorridoActivoKeys = {
  all: (sucursalId: number | null, transportistaId: string | null) =>
    ['recorrido-activo', sucursalId, transportistaId] as const,
}

// Embedding: recorrido → paradas (recorrido_pedidos) → pedido → cliente/items.
const RECORRIDO_ACTIVO_SELECT = `id, polylines,
  recorrido_pedidos(
    orden_entrega, estado_entrega, hora_entrega,
    pedido:pedidos(
      *,
      cliente:clientes(id, nombre_fantasia, razon_social, direccion, aclaracion_direccion, telefono, contacto, latitud, longitud, horarios_atencion),
      items:pedido_items(*, producto:productos(id, nombre, codigo, etiqueta_bulto, unidades_de_venta_por_fardo))
    )
  )`

interface RecorridoPedidoRaw {
  orden_entrega: number | null
  estado_entrega: string | null
  pedido: (Record<string, unknown> & { orden_entrega?: number | null }) | null
}

async function fetchRecorridoActivo(transportistaId: string): Promise<RecorridoActivo | null> {
  const { data, error } = await supabase
    .from('recorridos')
    .select(RECORRIDO_ACTIVO_SELECT)
    .eq('transportista_id', transportistaId)
    .eq('fecha', fechaLocalISO())
    .eq('estado', 'en_curso')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle()

  if (error) throw error
  if (!data) return null

  const rps = ((data.recorrido_pedidos as unknown as RecorridoPedidoRaw[]) || [])
    .filter(rp => rp.pedido != null)
    // El orden de entrega del recorrido es la fuente de verdad
    .sort((a, b) => (a.orden_entrega ?? 999) - (b.orden_entrega ?? 999))

  const paradas = rps.map(rp => ({
    ...(rp.pedido as object),
    orden_entrega: rp.orden_entrega ?? rp.pedido?.orden_entrega ?? null,
  })) as unknown as PedidoConCliente[]

  return {
    id: String(data.id),
    polylines: (data.polylines as string[] | null) ?? null,
    paradas,
  }
}

export function useRecorridoActivoQuery(transportistaId: string | null | undefined) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: recorridoActivoKeys.all(currentSucursalId, transportistaId ?? null),
    queryFn: () => fetchRecorridoActivo(transportistaId as string),
    enabled: !!transportistaId,
    staleTime: 60 * 1000,
  })
}

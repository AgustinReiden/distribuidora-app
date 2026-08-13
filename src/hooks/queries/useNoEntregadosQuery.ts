/**
 * No entregados por motivo y por barrida (migs 142/143/144).
 *
 * Es LA métrica de la tanda: el ruteo en barridas se hizo para que dejen de
 * volver 5-6 pedidos por día, y "CERRADO" era el 33% de las cancelaciones. Sin
 * este corte no hay forma de saber si el cambio sirvió — sólo la sensación de
 * que sí. Cruzar motivo × barrida es lo que responde la pregunta concreta:
 * ¿los que cierran al mediodía siguen quedando afuera?
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'

export interface NoEntregadoFila {
  motivo: string
  barrida: number | null
  cantidad: number
}

export interface NoEntregadosResumen {
  total: number
  porMotivo: Array<{ motivo: string; cantidad: number }>
  porBarrida: Array<{ barrida: number | null; cantidad: number }>
  /** Celdas motivo × barrida, para ver si un motivo se concentra en una barrida. */
  cruce: NoEntregadoFila[]
}

export const noEntregadosKeys = {
  all: (sucursalId: number | null) => ['no-entregados', sucursalId] as const,
  rango: (sucursalId: number | null, desde: string, hasta: string) =>
    [...noEntregadosKeys.all(sucursalId), desde, hasta] as const,
}

interface FilaCruda {
  motivo_no_entrega: string | null
  barrida: number | null
}

async function fetchNoEntregados(desde: string, hasta: string): Promise<NoEntregadosResumen> {
  // El filtro de fecha vive en `recorridos`; `!inner` lo convierte en join real
  // en vez de traer las paradas de todos los días y filtrar en el cliente.
  const { data, error } = await supabase
    .from('recorrido_pedidos')
    .select('motivo_no_entrega, barrida, recorridos!inner(fecha)')
    .eq('estado_entrega', 'no_entregado')
    .gte('recorridos.fecha', desde)
    .lte('recorridos.fecha', hasta)

  if (error) throw error

  const filas = (data as unknown as FilaCruda[]) || []
  const porMotivo = new Map<string, number>()
  const porBarrida = new Map<number | null, number>()
  const cruce = new Map<string, NoEntregadoFila>()

  for (const f of filas) {
    // Un no entregado sin motivo es de antes de que el motivo fuera obligatorio;
    // se cuenta igual, etiquetado, en vez de desaparecer del total.
    const motivo = f.motivo_no_entrega || 'sin_motivo'
    const barrida = f.barrida ?? null

    porMotivo.set(motivo, (porMotivo.get(motivo) || 0) + 1)
    porBarrida.set(barrida, (porBarrida.get(barrida) || 0) + 1)

    const key = `${motivo}|${barrida ?? 'x'}`
    const celda = cruce.get(key)
    if (celda) celda.cantidad += 1
    else cruce.set(key, { motivo, barrida, cantidad: 1 })
  }

  return {
    total: filas.length,
    porMotivo: [...porMotivo.entries()]
      .map(([motivo, cantidad]) => ({ motivo, cantidad }))
      .sort((a, b) => b.cantidad - a.cantidad),
    porBarrida: [...porBarrida.entries()]
      .map(([barrida, cantidad]) => ({ barrida, cantidad }))
      .sort((a, b) => (a.barrida ?? 99) - (b.barrida ?? 99)),
    cruce: [...cruce.values()].sort((a, b) => b.cantidad - a.cantidad),
  }
}

// ---------------------------------------------------------------------------
// Vista del preventista: qué pedidos MÍOS quedaron sin resolver.
//
// Esto consultaba `recorrido_pedidos` y NO FUNCIONABA para un preventista. La
// policy `mt_recorrido_pedidos_select` es `es_admin() OR (chofer dueño del
// recorrido)`: el preventista no entra por ninguna rama, la query volvía
// vacía SIN error (la RLS filtra, no falla) y el panel hacía `return null`.
// Era invisible justo para el rol al que apuntaba.
//
// Y encima la fuente estaba mal elegida: `marcar_no_entregado` (mig 144), que
// es lo que escribe en `recorrido_pedidos`, casi no se usa — 2 filas en toda
// la base. En la práctica el pedido que no se entrega se CANCELA con motivo
// tipificado, o se queda colgado en 'asignado'.
//
// Ahora sale del RPC `jornada_preventista_detalle(NULL)` (mig 179), que
// devuelve los pedidos del preventista todavía sin desenlace y ya resuelve el
// nombre del cliente (la RLS de `clientes` también lo escondía).
// ---------------------------------------------------------------------------

export interface PedidoSinResolver {
  pedidoId: string
  clienteNombre: string
  /** Día en que el preventista lo cargó: cuánto hace que está trabado. */
  fecha: string | null
  total: number
}

interface FilaPendiente {
  pedido_id: number
  cliente: string
  monto: number | null
  fecha_pedido: string | null
}

async function fetchPedidosSinResolver(): Promise<PedidoSinResolver[]> {
  const { data, error } = await supabase.rpc('jornada_preventista_detalle', {
    p_dia: null,
    p_preventista_id: null,
  })

  if (error) throw error

  return ((data as FilaPendiente[]) ?? []).map(f => ({
    pedidoId: String(f.pedido_id),
    clienteNombre: f.cliente,
    fecha: f.fecha_pedido,
    total: Number(f.monto ?? 0),
  }))
}

export function usePedidosSinResolverQuery(enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: [...noEntregadosKeys.all(currentSucursalId), 'sin-resolver'] as const,
    queryFn: fetchPedidosSinResolver,
    enabled,
    staleTime: 2 * 60 * 1000,
  })
}

export function useNoEntregadosQuery(desde: string, hasta: string, enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: noEntregadosKeys.rango(currentSucursalId, desde, hasta),
    queryFn: () => fetchNoEntregados(desde, hasta),
    enabled: enabled && Boolean(desde) && Boolean(hasta),
    staleTime: 2 * 60 * 1000,
  })
}

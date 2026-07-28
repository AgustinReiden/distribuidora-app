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
// Vista del preventista: qué pedidos MÍOS volvieron sin entregar y por qué.
//
// El pedido no entregado vuelve a 'pendiente' sin transportista (mig 144), así
// que en la lista de /pedidos se ve igual que uno recién cargado. Sin esto, el
// preventista se entera por la campanita y después el motivo se pierde.
//
// La RLS de `pedidos` ya acota: un preventista ve los suyos, un admin todos.
// ---------------------------------------------------------------------------

export interface PedidoRebotado {
  pedidoId: string
  clienteNombre: string
  motivo: string
  nota: string | null
  fecha: string | null
  total: number
}

interface FilaPedidoCruda {
  pedido_id: string
  motivo_no_entrega: string | null
  nota_no_entrega: string | null
  recorridos: { fecha: string } | { fecha: string }[] | null
  pedidos: {
    id: string
    total: number | null
    estado: string
    clientes: { nombre_fantasia: string | null; razon_social: string | null }
      | { nombre_fantasia: string | null; razon_social: string | null }[] | null
  } | null
}

/** PostgREST devuelve objeto o array según la cardinalidad que infiere. */
function primero<T>(v: T | T[] | null | undefined): T | null {
  if (!v) return null
  return Array.isArray(v) ? (v[0] ?? null) : v
}

async function fetchPedidosRebotados(dias: number): Promise<PedidoRebotado[]> {
  const desde = new Date()
  desde.setDate(desde.getDate() - dias)
  const desdeISO = desde.toISOString().slice(0, 10)

  const { data, error } = await supabase
    .from('recorrido_pedidos')
    .select(`
      pedido_id, motivo_no_entrega, nota_no_entrega,
      recorridos!inner(fecha),
      pedidos!inner(id, total, estado, clientes(nombre_fantasia, razon_social))
    `)
    .eq('estado_entrega', 'no_entregado')
    .gte('recorridos.fecha', desdeISO)
    .order('id', { ascending: false })

  if (error) throw error

  const filas = (data as unknown as FilaPedidoCruda[]) || []
  const vistos = new Set<string>()
  const out: PedidoRebotado[] = []

  for (const f of filas) {
    const pedido = primero(f.pedidos)
    // Ya entregado o cancelado = el problema se resolvió; no ensucia la lista.
    if (!pedido || pedido.estado === 'entregado' || pedido.estado === 'cancelado') continue
    // Un pedido puede haber rebotado más de una vez: vale el rebote más reciente.
    if (vistos.has(String(f.pedido_id))) continue
    vistos.add(String(f.pedido_id))

    const cliente = primero(pedido.clientes)
    out.push({
      pedidoId: String(f.pedido_id),
      clienteNombre: cliente?.nombre_fantasia || cliente?.razon_social || 'Cliente',
      motivo: f.motivo_no_entrega || 'sin_motivo',
      nota: f.nota_no_entrega,
      fecha: primero(f.recorridos)?.fecha ?? null,
      total: Number(pedido.total ?? 0),
    })
  }

  return out
}

export function usePedidosRebotadosQuery(dias = 30, enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: [...noEntregadosKeys.all(currentSucursalId), 'pedidos', dias] as const,
    queryFn: () => fetchPedidosRebotados(dias),
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

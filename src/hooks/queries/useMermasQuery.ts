/**
 * TanStack Query hooks para Mermas de Stock
 * Maneja registro y consulta de mermas con cache optimizado
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import type {
  MermaDBExtended,
  MermaFormInputExtended,
  MermaRegistroResult
} from '../../types'
import { productosKeys } from './useProductosQuery'
import { rangoArgentino, type FiltrosRangoFecha } from '../../utils/rangoArgentino'

// Query keys
export const mermasKeys = {
  all: (sucursalId: number | null) => ['mermas', sucursalId] as const,
  lists: (sucursalId: number | null) => [...mermasKeys.all(sucursalId), 'list'] as const,
  list: (sucursalId: number | null, filters: Record<string, unknown>) => [...mermasKeys.lists(sucursalId), filters] as const,
  details: (sucursalId: number | null) => [...mermasKeys.all(sucursalId), 'detail'] as const,
  detail: (sucursalId: number | null, id: string) => [...mermasKeys.details(sucursalId), id] as const,
  byProducto: (sucursalId: number | null, productoId: string) => [...mermasKeys.all(sucursalId), 'producto', productoId] as const,
  byMotivo: (sucursalId: number | null, motivo: string) => [...mermasKeys.all(sucursalId), 'motivo', motivo] as const,
}

/**
 * Tope de filas por consulta. PostgREST corta solo y en SILENCIO: sin un límite
 * explícito la pantalla diría "todas" y estaría mostrando las N más recientes.
 * Explícito, la UI puede comparar `length` contra esto y avisar.
 */
export const LIMITE_MERMAS = 1000

export type FiltrosMermas = FiltrosRangoFecha

// El corte por fecha va al SERVIDOR, no al cliente: sin filtro la consulta trae
// todo y se come el tope de PostgREST. El índice `idx_mermas_fecha` sobre
// created_at DESC ya existe, así que es gratis. `rangoArgentino` (utils/) es
// la que resuelve el corte de día en hora Argentina contra el timestamptz.

// Fetch functions
async function fetchMermas(filtros?: FiltrosMermas): Promise<MermaDBExtended[]> {
  const rango = rangoArgentino(filtros)
  let query = supabase
    .from('mermas_stock')
    .select('*')
    .order('created_at', { ascending: false })
    .limit(LIMITE_MERMAS)

  if (rango.desde) query = query.gte('created_at', rango.desde)
  if (rango.hasta) query = query.lte('created_at', rango.hasta)

  const { data, error } = await query

  if (error) {
    if (error.message.includes('does not exist')) return []
    throw error
  }
  return (data || []) as MermaDBExtended[]
}

async function fetchMermasByProducto(productoId: string): Promise<MermaDBExtended[]> {
  const { data, error } = await supabase
    .from('mermas_stock')
    .select('*')
    .eq('producto_id', productoId)
    .order('created_at', { ascending: false })

  if (error) {
    if (error.message.includes('does not exist')) return []
    throw error
  }
  return (data || []) as MermaDBExtended[]
}

async function fetchMermasByMotivo(motivo: string): Promise<MermaDBExtended[]> {
  const { data, error } = await supabase
    .from('mermas_stock')
    .select('*')
    .eq('motivo', motivo)
    .order('created_at', { ascending: false })

  if (error) {
    if (error.message.includes('does not exist')) return []
    throw error
  }
  return (data || []) as MermaDBExtended[]
}

// Mutation functions

/**
 * Una sola RPC, una sola transacción (mig 232).
 *
 * Antes eran tres requests desde el navegador: INSERT de la merma, UPDATE de
 * `productos.stock` con el valor ABSOLUTO que el modal había calculado sobre su
 * snapshot, y un DELETE compensatorio a mano si el segundo fallaba. Dos mermas
 * de 10 sobre stock 100 escribían las dos `stock = 90`. La RPC manda la
 * CANTIDAD y el servidor hace `stock = stock - cantidad` con el producto
 * lockeado, así que la segunda espera y lee lo que dejó la primera.
 *
 * Tampoco viaja el usuario: `usuario_id` es `auth.uid()` server-side (MERMA-I),
 * que es lo único que no se puede falsificar desde el cliente.
 */
async function registrarMerma(
  mermaData: MermaFormInputExtended,
  sucursalId: number | null
): Promise<MermaRegistroResult> {
  if (sucursalId == null) {
    throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
  }

  const { data, error } = await supabase.rpc('registrar_merma_manual', {
    p_producto_id: mermaData.productoId,
    p_cantidad: mermaData.cantidad,
    p_motivo: mermaData.motivo,
    p_observaciones: mermaData.observaciones || null,
    p_sucursal_id: sucursalId
  })

  if (error) throw error

  const resultado = data as { ok: boolean; merma: MermaDBExtended } | null
  return { success: true, merma: resultado?.merma ?? null }
}

// Hooks

/**
 * Hook para obtener todas las mermas
 */
export function useMermasQuery(filtros?: FiltrosMermas) {
  const { currentSucursalId } = useSucursal()
  const desde = filtros?.desde ?? null
  const hasta = filtros?.hasta ?? null
  return useQuery({
    // `list` con los filtros adentro: dos rangos distintos son dos cachés
    // distintas, si no el segundo mostraría el resultado del primero.
    queryKey: mermasKeys.list(currentSucursalId, { desde, hasta }),
    queryFn: () => fetchMermas({ desde, hasta }),
    staleTime: 5 * 60 * 1000, // 5 minutos
  })
}

/**
 * Hook para obtener mermas por producto
 */
export function useMermasByProductoQuery(productoId: string) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: mermasKeys.byProducto(currentSucursalId, productoId),
    queryFn: () => fetchMermasByProducto(productoId),
    enabled: !!productoId,
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Hook para obtener mermas por motivo
 */
export function useMermasByMotivoQuery(motivo: string) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: mermasKeys.byMotivo(currentSucursalId, motivo),
    queryFn: () => fetchMermasByMotivo(motivo),
    enabled: !!motivo,
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Hook para registrar una merma
 */
export function useRegistrarMermaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: (mermaData: MermaFormInputExtended) => registrarMerma(mermaData, currentSucursalId),
    onSuccess: (result, variables) => {
      // Agregar merma al cache si fue creada
      if (result.merma) {
        queryClient.setQueryData<MermaDBExtended[]>(mermasKeys.lists(currentSucursalId), (old) => {
          if (!old) return [result.merma!]
          return [result.merma!, ...old]
        })
      }
      // Invalidar mermas del producto específico
      queryClient.invalidateQueries({ queryKey: mermasKeys.byProducto(currentSucursalId, variables.productoId) })
      // Invalidar productos (stock actualizado)
      queryClient.invalidateQueries({ queryKey: productosKeys.lists(currentSucursalId) })
    },
  })
}

/**
 * Hook helper para calcular resumen de mermas
 */
export function useMermasResumen(fechaDesde?: string | null, fechaHasta?: string | null) {
  const { data: mermas = [] } = useMermasQuery()

  let mermasFiltradas = [...mermas]

  if (fechaDesde) {
    const desde = fechaDesde.includes('T') ? fechaDesde.split('T')[0] : fechaDesde
    mermasFiltradas = mermasFiltradas.filter(m => (m.created_at || '') >= desde)
  }
  if (fechaHasta) {
    const hasta = fechaHasta.includes('T') ? fechaHasta.split('T')[0] : fechaHasta
    mermasFiltradas = mermasFiltradas.filter(m => (m.created_at || '') <= hasta + 'T23:59:59')
  }

  const porMotivo: Record<string, { cantidad: number; registros: number }> = {}
  mermasFiltradas.forEach(m => {
    if (!porMotivo[m.motivo]) {
      porMotivo[m.motivo] = { cantidad: 0, registros: 0 }
    }
    porMotivo[m.motivo].cantidad += m.cantidad
    porMotivo[m.motivo].registros += 1
  })

  return {
    totalUnidades: mermasFiltradas.reduce((sum, m) => sum + m.cantidad, 0),
    totalRegistros: mermasFiltradas.length,
    porMotivo
  }
}

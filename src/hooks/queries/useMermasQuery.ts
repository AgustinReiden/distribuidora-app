/**
 * TanStack Query hooks para Mermas de Stock
 * Maneja registro y consulta de mermas con cache optimizado
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import type {
  MermaDBExtended,
  MermaFormInputExtended,
  MermaRegistroResult
} from '../../types'
import { productosKeys } from './useProductosQuery'

// Query keys
export const mermasKeys = {
  all: ['mermas'] as const,
  lists: () => [...mermasKeys.all, 'list'] as const,
  list: (filters: Record<string, unknown>) => [...mermasKeys.lists(), filters] as const,
  details: () => [...mermasKeys.all, 'detail'] as const,
  detail: (id: string) => [...mermasKeys.details(), id] as const,
  byProducto: (productoId: string) => [...mermasKeys.all, 'producto', productoId] as const,
  byMotivo: (motivo: string) => [...mermasKeys.all, 'motivo', motivo] as const,
}

// Fetch functions
async function fetchMermas(): Promise<MermaDBExtended[]> {
  const { data, error } = await supabase
    .from('mermas_stock')
    .select('*')
    .order('created_at', { ascending: false })

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
async function registrarMerma(mermaData: MermaFormInputExtended): Promise<MermaRegistroResult> {
  // Primero intentar insertar la merma (para fallar antes de modificar stock)
  const { data, error } = await supabase
    .from('mermas_stock')
    .insert([{
      producto_id: mermaData.productoId,
      cantidad: mermaData.cantidad,
      motivo: mermaData.motivo,
      observaciones: mermaData.observaciones || null,
      stock_anterior: mermaData.stockAnterior,
      stock_nuevo: mermaData.stockNuevo,
      usuario_id: mermaData.usuarioId || null
    }])
    .select()
    .single()

  if (error) {
    // Si la tabla no existe, solo actualizar stock (modo fallback)
    if (error.message.includes('does not exist')) {
      const { error: stockError } = await supabase
        .from('productos')
        .update({ stock: mermaData.stockNuevo })
        .eq('id', mermaData.productoId)
      if (stockError) throw stockError
      return { success: true, merma: null, soloStock: true }
    }
    throw error
  }

  const mermaCreada = data as MermaDBExtended

  // La merma se insertó correctamente, ahora actualizar stock
  const { error: stockError } = await supabase
    .from('productos')
    .update({ stock: mermaData.stockNuevo })
    .eq('id', mermaData.productoId)

  if (stockError) {
    // Revertir: eliminar la merma si el stock falla
    await supabase.from('mermas_stock').delete().eq('id', mermaCreada.id)
    throw stockError
  }

  return { success: true, merma: mermaCreada }
}

// Hooks

/**
 * Hook para obtener todas las mermas
 */
export function useMermasQuery() {
  return useQuery({
    queryKey: mermasKeys.lists(),
    queryFn: fetchMermas,
    staleTime: 5 * 60 * 1000, // 5 minutos
  })
}

/**
 * Hook para obtener mermas por producto
 */
export function useMermasByProductoQuery(productoId: string) {
  return useQuery({
    queryKey: mermasKeys.byProducto(productoId),
    queryFn: () => fetchMermasByProducto(productoId),
    enabled: !!productoId,
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Hook para obtener mermas por motivo
 */
export function useMermasByMotivoQuery(motivo: string) {
  return useQuery({
    queryKey: mermasKeys.byMotivo(motivo),
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

  return useMutation({
    mutationFn: registrarMerma,
    onSuccess: (result, variables) => {
      // Agregar merma al cache si fue creada
      if (result.merma) {
        queryClient.setQueryData<MermaDBExtended[]>(mermasKeys.lists(), (old) => {
          if (!old) return [result.merma!]
          return [result.merma!, ...old]
        })
      }
      // Invalidar mermas del producto específico
      queryClient.invalidateQueries({ queryKey: mermasKeys.byProducto(variables.productoId) })
      // Invalidar productos (stock actualizado)
      queryClient.invalidateQueries({ queryKey: productosKeys.lists() })
      queryClient.invalidateQueries({ queryKey: productosKeys.stockBajo(10) })
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

/**
 * TanStack Query hooks para Notas de Credito
 * Permite consultar y registrar notas de credito asociadas a compras
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import type { NotaCreditoDB, NotaCreditoFormInput } from '../../types'
import { comprasKeys } from './useComprasQuery'

// Resumen ligero de NCs por compra (para badges en lista)
export interface NCResumen {
  compra_id: string
  cantidad: number
  total: number
}

// Query keys
export const notasCreditoKeys = {
  all: ['notas_credito'] as const,
  lists: () => [...notasCreditoKeys.all, 'list'] as const,
  resumen: () => [...notasCreditoKeys.all, 'resumen'] as const,
  byCompra: (compraId: string) => [...notasCreditoKeys.all, 'compra', compraId] as const,
}

// Fetch functions
async function fetchNotasCreditoResumen(): Promise<NCResumen[]> {
  const { data, error } = await supabase
    .from('notas_credito')
    .select('compra_id, total')

  if (error) {
    if (error.message.includes('does not exist')) return []
    throw error
  }

  // Agrupar por compra_id
  const map = new Map<string, NCResumen>()
  for (const row of data || []) {
    const key = String(row.compra_id)
    const existing = map.get(key)
    if (existing) {
      existing.cantidad += 1
      existing.total += Number(row.total) || 0
    } else {
      map.set(key, { compra_id: key, cantidad: 1, total: Number(row.total) || 0 })
    }
  }
  return Array.from(map.values())
}

async function fetchNotasCreditoByCompra(compraId: string): Promise<NotaCreditoDB[]> {
  const { data, error } = await supabase
    .from('notas_credito')
    .select(`
      *,
      items:nota_credito_items(*, producto:productos(*)),
      usuario:perfiles(id, nombre)
    `)
    .eq('compra_id', compraId)
    .order('created_at', { ascending: false })

  if (error) {
    if (error.message.includes('does not exist')) return []
    throw error
  }
  return (data || []) as NotaCreditoDB[]
}

// Mutation functions
async function registrarNotaCredito(data: NotaCreditoFormInput): Promise<void> {
  const itemsParaRPC = data.items.map(item => ({
    producto_id: item.productoId,
    cantidad: item.cantidad,
    costo_unitario: item.costoUnitario,
    subtotal: item.subtotal,
  }))

  const { data: result, error } = await supabase.rpc('registrar_nota_credito', {
    p_compra_id: data.compraId,
    p_numero_nota: data.numeroNota || null,
    p_motivo: data.motivo || null,
    p_subtotal: data.subtotal,
    p_iva: data.iva,
    p_total: data.total,
    p_usuario_id: data.usuarioId || null,
    p_items: itemsParaRPC,
  })

  if (error) throw error

  const rpcResult = result as { success?: boolean; error?: string } | null
  if (rpcResult && !rpcResult.success) {
    throw new Error(rpcResult.error || 'Error al registrar nota de credito')
  }
}

// Hooks

/**
 * Hook para obtener notas de credito de una compra
 */
export function useNotasCreditoByCompraQuery(compraId: string | undefined, enabled = true) {
  return useQuery({
    queryKey: notasCreditoKeys.byCompra(compraId || ''),
    queryFn: () => fetchNotasCreditoByCompra(compraId!),
    enabled: !!compraId && enabled,
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Hook para obtener resumen de NCs por compra (para badges en lista)
 */
export function useNotasCreditoResumenQuery() {
  return useQuery({
    queryKey: notasCreditoKeys.resumen(),
    queryFn: fetchNotasCreditoResumen,
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Hook para registrar una nota de credito
 */
export function useRegistrarNotaCreditoMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: registrarNotaCredito,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: comprasKeys.lists() })
      queryClient.invalidateQueries({ queryKey: ['productos'] })
      queryClient.invalidateQueries({ queryKey: notasCreditoKeys.all })
    },
  })
}

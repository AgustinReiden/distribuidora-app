/**
 * TanStack Query hook para registrar mermas de stock
 */
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import type {
  MermaDBExtended,
  MermaFormInputExtended,
  MermaRegistroResult
} from '../../types'
import { productosKeys } from './useProductosQuery'

// Query keys. `list`/`details`/`detail`/`byMotivo` no existen: sin lectura de
// mermas en la app (#574, reemplazada por reporte_mermas), lo único que queda
// es lo que invalida `useRegistrarMermaMutation` y `useLotesQuery`.
export const mermasKeys = {
  all: (sucursalId: number | null) => ['mermas', sucursalId] as const,
  lists: (sucursalId: number | null) => [...mermasKeys.all(sucursalId), 'list'] as const,
  byProducto: (sucursalId: number | null, productoId: string) => [...mermasKeys.all(sucursalId), 'producto', productoId] as const,
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

/**
 * Hook mutation para sustituir un regalo de promocion por otro producto.
 *
 * Backend: RPC `sustituir_regalo_pedido` (mig 058). Solo admin/encargado.
 * Idempotente via `client_request_id` — el caller puede pasar un UUID o
 * dejar que el hook lo genere (default).
 *
 * Maneja respuestas `{ success: false, error: '...' }` del RPC convirtiendo
 * el error a Error JS para que onError se dispare en TanStack Query.
 */
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import type { SustituirRegaloInput, SustituirRegaloResult } from '../../types'

async function sustituirRegalo(input: SustituirRegaloInput): Promise<SustituirRegaloResult> {
  const clientRequestId = input.clientRequestId ?? crypto.randomUUID()

  const { data, error } = await supabase.rpc('sustituir_regalo_pedido', {
    p_pedido_item_id: input.pedidoItemId,
    p_producto_nuevo_id: input.productoNuevoId,
    p_cantidad_nueva: input.cantidadNueva,
    p_motivo: input.motivo,
    p_client_request_id: clientRequestId,
  })
  if (error) throw error

  const raw = (data ?? {}) as {
    success?: boolean
    error?: string
    sustitucion_id?: string
    modo?: 'A' | 'B'
    idempotent_replay?: boolean
  }
  if (!raw.success) {
    throw new Error(raw.error || 'Error al sustituir el regalo')
  }
  return {
    sustitucionId: String(raw.sustitucion_id ?? ''),
    modo: raw.modo ?? 'A',
    idempotentReplay: raw.idempotent_replay,
  }
}

/**
 * Hook que expone la mutation. En `onSuccess` invalida pedidos + productos
 * para que la UI vea el nuevo stock y la nueva composicion del pedido.
 */
export function useSustituirRegaloMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: sustituirRegalo,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
      queryClient.invalidateQueries({ queryKey: ['productos'] })
    },
  })
}

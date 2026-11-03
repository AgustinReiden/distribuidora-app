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
import type {
  DividirRegaloInput,
  DividirRegaloResult,
  SustituirRegaloInput,
  SustituirRegaloResult,
} from '../../types'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import type { CambioDeVersion } from '../../utils/versionPedido'

/** #1376: las dos RPCs mueven `pedidos.updated_at` y devuelven el de antes y el nuevo. */
function versionDe(raw: { updated_at_anterior?: string; updated_at?: string }): CambioDeVersion | undefined {
  return raw.updated_at_anterior && raw.updated_at
    ? { anterior: raw.updated_at_anterior, nueva: raw.updated_at }
    : undefined
}

async function sustituirRegalo(input: SustituirRegaloInput): Promise<SustituirRegaloResult> {
  const clientRequestId = input.clientRequestId ?? crypto.randomUUID()

  const { data, error } = await supabase.rpc('sustituir_regalo_pedido', {
    p_pedido_item_id: input.pedidoItemId,
    p_producto_nuevo_id: input.productoNuevoId,
    p_cantidad_nueva: input.cantidadNueva,
    p_motivo: input.motivo,
    p_ajuste_producto_id_nuevo: input.ajusteProductoIdNuevo ?? null,
    p_client_request_id: clientRequestId,
  })
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la sustitución del regalo. Revisá si quedó hecho antes de reintentar.')

  const raw = (data ?? {}) as {
    success?: boolean
    error?: string
    sustitucion_id?: string
    modo?: 'A' | 'B'
    idempotent_replay?: boolean
    updated_at_anterior?: string
    updated_at?: string
  }
  if (!raw.success) {
    throw new Error(raw.error || 'Error al sustituir el regalo')
  }
  return {
    sustitucionId: String(raw.sustitucion_id ?? ''),
    modo: raw.modo ?? 'A',
    idempotentReplay: raw.idempotent_replay,
    version: versionDe(raw),
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

/**
 * Reparto de un regalo en varios sabores (mig 275, #831). Backend: RPC
 * `dividir_regalo_pedido`. Mismas reglas que la sustitucion (admin/encargado,
 * pedido no entregado) mas una: la suma de las partes tiene que ser la
 * cantidad de la linea. Idempotente via `client_request_id`.
 */
async function dividirRegalo(input: DividirRegaloInput): Promise<DividirRegaloResult> {
  const clientRequestId = input.clientRequestId ?? crypto.randomUUID()

  const { data, error } = await supabase.rpc('dividir_regalo_pedido', {
    p_pedido_item_id: input.pedidoItemId,
    p_partes: input.partes.map(p => ({ producto_id: p.productoId, cantidad: p.cantidad })),
    p_motivo: input.motivo,
    p_client_request_id: clientRequestId,
  })
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el reparto del regalo. Revisá si quedó hecho antes de reintentar.')

  const raw = (data ?? {}) as {
    success?: boolean
    error?: string
    sustitucion_id?: string | number
    reparto_id?: string
    modo?: 'A' | 'B'
    idempotent_replay?: boolean
    updated_at_anterior?: string
    updated_at?: string
  }
  if (!raw.success) {
    throw new Error(raw.error || 'Error al repartir el regalo')
  }
  return {
    sustitucionId: String(raw.sustitucion_id ?? ''),
    repartoId: String(raw.reparto_id ?? ''),
    modo: raw.modo ?? 'A',
    idempotentReplay: raw.idempotent_replay,
    version: versionDe(raw),
  }
}

export function useDividirRegaloMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: dividirRegalo,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
      queryClient.invalidateQueries({ queryKey: ['productos'] })
      queryClient.invalidateQueries({ queryKey: ['pedido-sustituciones'] })
    },
  })
}

/**
 * TanStack Query hook para vinculación de Telegram Bot
 *
 * Wraps la RPC `generar_codigo_vinculacion_bot` (migración 014_bot_telegram.sql).
 *
 * Importante: el frontend NO necesita pasar `perfil_id`. La RPC usa
 * `auth.uid()` internamente para identificar al usuario authenticated, así que
 * cualquier sesión válida puede generar SU PROPIO código de vinculación.
 *
 * La RPC retorna el código TEXT directamente (no JSON). El hook lo envuelve en
 * un objeto `{ codigo, expira_at, generado_at }` para conveniencia de la UI:
 * la RPC garantiza TTL de 10 minutos, así que `expira_at` se calcula client-side
 * sumando 10 min al `now()` del navegador (suficiente para mostrar countdown).
 */
import { useMutation, type UseMutationResult } from '@tanstack/react-query'
import { supabase } from '../supabase/base'

/**
 * Resultado del RPC `generar_codigo_vinculacion_bot`, normalizado para la UI.
 */
export interface CodigoVinculacionResult {
  /** Código OTP de 6 chars en mayúsculas (ej: "ABC123"). */
  codigo: string
  /** Timestamp ISO de expiración (now + 10 min, calculado client-side). */
  expira_at: string
  /** Timestamp ISO en el que se generó el código (now() del cliente). */
  generado_at: string
}

/**
 * Query keys para vinculación de bot. Mantiene la convención del repo (mirá
 * `usuariosKeys`, `productosKeys`, etc.) aunque por ahora no haya queries
 * cacheadas — útil para invalidaciones futuras.
 */
export const botVinculacionKeys = {
  all: ['bot-vinculacion'] as const,
  codigo: () => [...botVinculacionKeys.all, 'codigo'] as const,
}

/** TTL fijo de la RPC (10 minutos) — debe matchear migrations/014_bot_telegram.sql. */
const TTL_MS = 10 * 60 * 1000

async function generarCodigoVinculacionBot(): Promise<CodigoVinculacionResult> {
  const { data, error } = await supabase.rpc('generar_codigo_vinculacion_bot')

  if (error) {
    throw error
  }

  if (typeof data !== 'string' || data.length === 0) {
    throw new Error('La RPC no retornó un código válido')
  }

  const generadoAt = new Date()
  const expiraAt = new Date(generadoAt.getTime() + TTL_MS)

  return {
    codigo: data.toUpperCase(),
    expira_at: expiraAt.toISOString(),
    generado_at: generadoAt.toISOString(),
  }
}

/**
 * Mutation que llama al RPC `generar_codigo_vinculacion_bot` y retorna
 * `{ codigo, expira_at, generado_at }`.
 *
 * No invalida ninguna query (la RPC invalida el código previo del usuario
 * server-side, así que no hay state cacheado que tocar). Para regenerar,
 * llamá `mutate()` o `mutateAsync()` de nuevo y se descarta el código previo.
 *
 * @example
 * const { mutate, data, isPending, error } = useGenerarCodigoVinculacionBot()
 * mutate() // dispara la RPC; data tendrá el código en el siguiente render.
 */
export function useGenerarCodigoVinculacionBot(): UseMutationResult<CodigoVinculacionResult, Error, void> {
  return useMutation<CodigoVinculacionResult, Error, void>({
    mutationFn: generarCodigoVinculacionBot,
  })
}

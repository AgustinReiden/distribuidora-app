/**
 * TanStack Query hook para vinculación de Telegram Bot
 *
 * Wraps la RPC `generar_codigo_vinculacion_bot` (migración 014_bot_telegram.sql).
 *
 * Importante: el frontend NO necesita pasar `perfil_id`. La RPC usa
 * `auth.uid()` internamente para identificar al usuario autenticado, así que
 * cualquier sesión válida puede generar SU PROPIO código de vinculación.
 *
 * La RPC retorna jsonb con shape `{ codigo, expira_at }`. El `expira_at` viene
 * del server (now() + 10 min calculado en Postgres) — esto evita drift cuando
 * el reloj del navegador está desincronizado, que se manifestaría como
 * countdowns incorrectos en la UI. El hook agrega `generado_at` (now() del
 * cliente, solo informativo, no usado para el countdown).
 */
import { useMutation, type UseMutationResult } from '@tanstack/react-query'
import { supabase } from '../supabase/base'

/**
 * Resultado del RPC `generar_codigo_vinculacion_bot`, normalizado para la UI.
 */
export interface CodigoVinculacionResult {
  /** Código OTP de 6 chars en mayúsculas (ej: "ABC123"). */
  codigo: string
  /** Timestamp ISO de expiración (server-side: now() + 10 min en Postgres). */
  expira_at: string
  /** Timestamp ISO en el que se generó el código (now() del cliente, informativo). */
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

/**
 * Type guard interno: la RPC retorna jsonb arbitrario, así que validamos
 * que tenga la shape esperada antes de confiar en los campos.
 */
interface RpcCodigoPayload {
  codigo: string
  expira_at: string
}
function isRpcCodigoPayload(v: unknown): v is RpcCodigoPayload {
  if (typeof v !== 'object' || v === null) return false
  const obj = v as Record<string, unknown>
  return typeof obj.codigo === 'string' && typeof obj.expira_at === 'string'
}

async function generarCodigoVinculacionBot(): Promise<CodigoVinculacionResult> {
  const { data, error } = await supabase.rpc('generar_codigo_vinculacion_bot')

  if (error) {
    throw error
  }

  if (!isRpcCodigoPayload(data)) {
    throw new Error('La RPC no retornó un payload válido')
  }

  const codigo = data.codigo.toUpperCase()
  const expiraAtIso = new Date(data.expira_at).toISOString()

  if (!codigo || !expiraAtIso) {
    throw new Error('La RPC retornó datos incompletos')
  }

  return {
    codigo,
    expira_at: expiraAtIso,
    generado_at: new Date().toISOString(),
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

/**
 * Convierte lo que devuelve supabase-js en un Error de verdad.
 *
 * SUPABASE-JS NO LANZA Error. Sin `.throwOnError()` —que no se usa en ningún
 * lado del repo— `PostgrestError` nunca se instancia: el `error` que vuelve es
 * un OBJETO PLANO. Son dos formas distintas y ninguna es un `Error`:
 *
 *   - respondió el servidor → el JSON de PostgREST,
 *     `{ message, details, hint, code: 'P0001' }`
 *   - no hubo servidor      → lo arma el `catch` del fetch,
 *     `{ message: 'TypeError: Failed to fetch', details, hint, code: '' }`
 *
 * Por eso todo `err instanceof Error ? err.message : '<generico>'` de la UI da
 * **siempre** false en este camino y muestra su texto de fallback. Pasó con la
 * baja de stock (#518 dejó la RPC, pero el mensaje no llegaba a la pantalla):
 * el modal mostraba "Error al registrar la merma" y el toast "Error al
 * registrar merma" —sus dos literales— tanto para "se requiere rol admin" como
 * para un blip de 4G. El mismo malentendido ya había vuelto inerte a
 * `isTransientNetworkError` hasta 2026-08.
 *
 * El discriminante entre "dijo que no" y "no se pudo preguntar" es el `code`,
 * no el tipo ni `navigator.onLine`: los errores semánticos del servidor
 * (`P0001` de un RAISE, `42501`, `PGRST2xx`) traen uno y los de red traen `''`.
 * Mirar `navigator.onLine` primero —que en un celular con señal mala miente en
 * los dos sentidos— taparía el mensaje del servidor con un "sin conexión".
 */
import { getErrorMessage } from './errorHandling'
import { esFalloDeRed } from './falloDeRed'

export function errorDeSupabase(error: unknown, mensajeSinConexion: string): Error {
  const code = (error as { code?: unknown } | null | undefined)?.code
  const huboServidor = typeof code === 'string' ? code !== '' : code != null

  if (!huboServidor && esFalloDeRed(error)) {
    return new Error(mensajeSinConexion)
  }
  return new Error(getErrorMessage(error))
}

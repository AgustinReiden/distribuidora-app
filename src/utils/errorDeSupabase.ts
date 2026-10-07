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

/**
 * El  normalizado conserva lo que la UI y el reintento leen del objeto
 * original:  (VistaMisEntregas distingue 42501 de lo demás),
 *  y . Y  marca el fallo de red: el mensaje
 * traducido ya no dice 'failed to fetch', así que  * no lo reconocería por el texto y el reintento se apagaría sin avisar.
 */
export class ErrorDeSupabase extends Error {
  code?: string | number
  details?: unknown
  hint?: unknown
  sinServidor: boolean

  constructor(message: string, origen: unknown, sinServidor: boolean) {
    super(message)
    this.name = 'ErrorDeSupabase'
    const o = (origen ?? {}) as { code?: string | number; details?: unknown; hint?: unknown }
    this.code = o.code
    this.details = o.details
    this.hint = o.hint
    this.sinServidor = sinServidor
  }
}

export function errorDeSupabase(error: unknown, mensajeSinConexion: string): ErrorDeSupabase {
  const code = (error as { code?: unknown } | null | undefined)?.code
  const huboServidor = typeof code === 'string' ? code !== '' : code != null

  if (!huboServidor && esFalloDeRed(error)) {
    return new ErrorDeSupabase(mensajeSinConexion, error, true)
  }
  // Un `message` vacío con `code` de servidor daría un Error en blanco: peor que el literal de la UI.
  return new ErrorDeSupabase(getErrorMessage(error).trim() || 'Error del servidor', error, false)
}

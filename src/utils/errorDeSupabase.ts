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

/**
 * Códigos con servidor que SÍ conviene reintentar: la transacción se abortó
 * entera (40001 serialización, 40P01 deadlock: los dos piden "probá de nuevo")
 * o la base no estaba atendiendo (clase 08, 53300, 57P01-03, y los PGRST000-003
 * de PostgREST sin conexión al pool). Lo demás con `code` es una respuesta:
 * 42501, PGRST201/203, 22P02 o un RAISE van a fallar igual la segunda vez.
 * 57014 (statement_timeout) queda afuera a propósito: repetir la consulta pesada
 * que se pasó de tiempo sólo le suma carga a la base.
 */
const CODIGOS_TRANSITORIOS = new Set([
  '40001', '40P01', '53300', '57P01', '57P02', '57P03',
  'PGRST000', 'PGRST001', 'PGRST002', 'PGRST003',
])

/**
 * ¿Vale la pena repetir el pedido? Mismo discriminante que `errorDeSupabase`:
 * sin `code` no hubo respuesta del servidor (red, timeout, un 502 con cuerpo
 * HTML de un proxy) y se reintenta; con `code` sólo si es transitorio.
 */
export function esErrorReintentable(error: unknown): boolean {
  const code = (error as { code?: unknown } | null | undefined)?.code
  if (typeof code === 'number') return false
  if (typeof code !== 'string' || code === '') return true
  return CODIGOS_TRANSITORIOS.has(code) || code.startsWith('08')
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

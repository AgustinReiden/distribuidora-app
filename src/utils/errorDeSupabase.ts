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
 * los dos sentidos— taparía el mensaje del servidor con un "sin conexión". Lo que
 * contesta un gateway en lugar de PostgREST trae un `code` sintético, con su
 * status (ver `respuestaDeErrorLegible`).
 */
import { getErrorMessage } from './errorHandling'
import { esFalloDeRed, esGatewayCaido } from './falloDeRed'

/**
 * El `ErrorDeSupabase` normalizado conserva lo que la UI y el reintento leen del
 * objeto original: `code` (VistaMisEntregas distingue 42501 de lo demás),
 * `details` y `hint`. Y `sinServidor` marca el fallo de red: el mensaje
 * traducido ya no dice 'failed to fetch', así que `isTransientNetworkError` no
 * lo reconocería por el texto y el reintento se apagaría sin avisar.
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
 * entera (40001 serialización, 40P01 deadlock, 55P03 lock_timeout: piden "probá
 * de nuevo") o la base no estaba atendiendo (clase 08, 53300, 57P01-03, y los
 * PGRST000-003 de PostgREST sin conexión al pool). Lo demás con `code` de la base
 * o de PostgREST es una respuesta: 42501, PGRST201/203, 22P02 o un RAISE van a
 * fallar igual la segunda vez.
 * 57014 (statement_timeout) queda afuera a propósito: repetir la consulta pesada
 * que se pasó de tiempo sólo le suma carga a la base. Los JWT (`CODIGOS_JWT`)
 * también se reintentan: supabase-js renueva el token solo y el segundo intento
 * sale con el nuevo.
 */
const CODIGOS_JWT = new Set(['PGRST301', 'PGRST303'])
const CODIGOS_TRANSITORIOS = new Set([
  '40001', '40P01', '55P03', '53300', '57P01', '57P02', '57P03',
  'PGRST000', 'PGRST001', 'PGRST002', 'PGRST003',
  ...CODIGOS_JWT,
])

/** PostgREST rechazó el JWT. Según la versión, "JWT expired" sale con uno u otro. */
export function esErrorDeJwt(error: unknown): boolean {
  const code = (error as { code?: unknown } | null | undefined)?.code
  return typeof code === 'string' && CODIGOS_JWT.has(code)
}

/**
 * ¿Vale la pena repetir el pedido? Con `code`, sólo si es transitorio o un 5xx de
 * gateway. Sin `code` decide el status, si lo hay: un `FunctionsHttpError` lo trae
 * en `context` y uno de auth, en `status`.
 *
 * Sin status, el objeto plano de supabase-js es un fallo de red o una respuesta
 * que no se pudo leer, y se reintenta. Un `Error`, también el `ErrorDeSupabase`,
 * sólo si es un fallo de red: si no, es un bug del queryFn o un rechazo, y
 * repetirlo sólo atrasa el mensaje (#1304).
 */
export function esErrorReintentable(error: unknown): boolean {
  const e = error as { code?: unknown; status?: unknown; context?: { status?: unknown } } | null | undefined
  const code = e?.code
  if (typeof code === 'number') return false
  if (typeof code === 'string' && code !== '') {
    return CODIGOS_TRANSITORIOS.has(code) || code.startsWith('08') || esGatewayCaido(error)
  }

  const status = e?.status ?? e?.context?.status
  if (typeof status === 'number' && status > 0) return status >= 500

  if (!(error instanceof Error)) return true
  return error.name === 'FunctionsFetchError' || esFalloDeRed(error)
}

/**
 * El status de una respuesta que no es de PostgREST, antes de que se pierda.
 *
 * Un gateway (Cloudflare, Kong) contesta sin pasar por PostgREST, y postgrest-js
 * deja el cuerpo en `{ message }`: el HTML entero, sin `code` y sin `status`, que
 * se queda en la respuesta y no en el error. Sin esto un 524 era indistinguible
 * por el texto, y el HTML llegaba al banner de la cola y a los mensajes (#1304).
 * Lo reescribe el `fetch` de `supabase.ts`, que es el único que ve el status.
 *
 * El `code` sintético `HTTP_<status>` hace que el resto lo trate como cualquier
 * respuesta del servidor: la cola le gasta un reintento en vez de dejarlo
 * pendiente sin límite (#1264), y `esErrorReintentable` repite los 5xx. No se
 * tocan el error de PostgREST (su `code` es la respuesta) ni un 4xx con JSON o
 * vacío: se entienden solos, y postgrest-js toma el 404 vacío como "sin
 * contenido".
 */
export async function respuestaDeErrorLegible(res: Response): Promise<Response> {
  if (res.ok) return res

  const cuerpo = await res.clone().text()
  let json: { code?: unknown } | null | undefined
  try {
    json = JSON.parse(cuerpo)
  } catch {
    json = undefined
  }

  if (typeof json?.code === 'string' && json.code !== '') return res
  if (res.status < 500 && (cuerpo === '' || json !== undefined)) return res

  // Un 4xx es definitivo: el gateway lo rechazó sin llegar a la base, la
  // operación no entró. Sólo un 5xx deja la duda de si quedó hecha (#1373).
  const message = res.status < 500
    ? `Error del servidor (HTTP ${res.status}): la operación no se realizó.`
    : `Error del servidor (HTTP ${res.status}): no se pudo confirmar la operación. Revisá si quedó hecha antes de reintentar.`

  return new Response(
    JSON.stringify({
      message,
      details: null,
      hint: null,
      code: `HTTP_${res.status}`,
    }),
    { status: res.status, statusText: res.statusText },
  )
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

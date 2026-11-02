/**
 * Retry generico con backoff exponencial para operaciones que pueden fallar
 * transientemente (errores de fetch, network, timeout).
 *
 * Tipico uso: envolver una llamada a supabase.rpc cuando el RPC es idempotente
 * server-side (ej. acepta client_request_id). NO usar para operaciones no
 * idempotentes: el retry duplicaria efectos si la primera request llego al
 * servidor pero la respuesta se perdio.
 */
import { getErrorMessage } from './errorHandling'

export interface RetryOptions {
  maxAttempts?: number
  initialDelayMs?: number
  multiplier?: number
  shouldRetry: (err: unknown) => boolean
}

export async function retryWithBackoff<T>(
  fn: () => Promise<T>,
  opts: RetryOptions,
): Promise<T> {
  const { maxAttempts = 3, initialDelayMs = 500, multiplier = 2, shouldRetry } = opts
  let lastError: unknown
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await fn()
    } catch (err) {
      lastError = err
      if (attempt === maxAttempts || !shouldRetry(err)) throw err
      const delay = initialDelayMs * Math.pow(multiplier, attempt - 1)
      await new Promise((r) => setTimeout(r, delay))
    }
  }
  throw lastError
}

/**
 * Un intento se quedó sin plazo: con señal que no pasa datos un request no falla,
 * queda colgado. Lleva `sinServidor` como el resto de los fallos de red: no se
 * sabe si el servidor lo recibió, así que sólo es seguro donde el reintento es
 * idempotente. Se llama como el error de `AbortSignal.timeout()`: es la razón del
 * abort, y postgrest-js arma su mensaje con `${name}: ${message}`, que así se
 * reconoce como fallo de red aunque vuelva por ese lado.
 */
export class PlazoDeRedVencido extends Error {
  readonly sinServidor = true

  constructor(ms: number) {
    super(`Sin respuesta del servidor en ${Math.round(ms / 1000)} s`)
    this.name = 'TimeoutError'
  }
}

/**
 * Corre `fn` con un plazo. La carrera corta aunque el intento no esté en el
 * `fetch`: supabase-js espera el token antes de llamarlo, y una mutation sin red
 * se pausa, así que el `signal` solo no alcanza. El `signal` es para que además
 * se corte el request de verdad.
 */
export async function conPlazoDeRed<T>(
  fn: (signal: AbortSignal) => Promise<T>,
  ms: number,
): Promise<T> {
  const controlador = new AbortController()
  let timer: ReturnType<typeof setTimeout> | undefined
  const vencido = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      const error = new PlazoDeRedVencido(ms)
      // El rechazo antes que el abort: al revés, gana la carrera el error del
      // fetch abortado y se pierde que fue el plazo.
      reject(error)
      controlador.abort(error)
    }, ms)
  })
  try {
    return await Promise.race([fn(controlador.signal), vencido])
  } finally {
    clearTimeout(timer)
  }
}

/**
 * Heuristica de errores de red transitorios. Cubre Safari/WebKit ("Load
 * failed"), Chrome/Android ("Failed to fetch"), variantes de timeout y
 * NetworkError.
 *
 * OJO CON EL DISCRIMINANTE. Hasta 2026-08 esto arrancaba con
 * `if (!(err instanceof Error)) return false`, y eso volvia inerte a toda la
 * capa de reintento: supabase-js **no lanza Error**. `PostgrestError` solo se
 * instancia con `.throwOnError()`, que no se usa en ningun lado del repo; sin
 * el, un fallo de red vuelve como objeto plano
 * `{ message: "TypeError: Failed to fetch", details, hint, code: '' }`.
 * O sea que `shouldRetry` daba false justo para el caso que motivo el helper, y
 * los 5 call sites hacian 1 solo intento — el chofer perdia el cobro al primer
 * blip de red, que en la calle es lo normal.
 *
 * Lo que el guard viejo SI queria evitar era reintentar un error semantico del
 * servidor (23505 duplicado, 42501 permisos, PGRST203 sobrecarga ambigua):
 * reintentarlos no cambia nada. Eso se discrimina por el `code`, no por el tipo:
 * los semanticos traen un codigo no vacio y los de red traen `code: ''`.
 *
 * Y un objeto plano SIN la clave `code` tampoco es de red: es el `{ message }` que
 * arma postgrest-js con un cuerpo que no es de PostgREST, o sea que alguien
 * respondio (#1304). Un gateway escribe "timeout" en su HTML, y ese texto volvia
 * pendiente para siempre a un pedido en la cola, sin gastar reintentos.
 */
export function isTransientNetworkError(err: unknown): boolean {
  // Un error ya normalizado por errorDeSupabase trae traducido el mensaje de red
  // (no dice 'failed to fetch'), pero lleva la marca de que no hubo servidor. Sin
  // esa marca, lo que diga el mensaje ya no cuenta.
  const sinServidor = (err as { sinServidor?: unknown } | null | undefined)?.sinServidor
  if (typeof sinServidor === 'boolean') return sinServidor

  const code = (err as { code?: unknown } | null | undefined)?.code
  if (typeof code === 'string' && code !== '') return false
  if (typeof code === 'number') return false
  if (typeof err === 'object' && err !== null && !(err instanceof Error) && !('code' in err)) return false

  const m = getErrorMessage(err).toLowerCase()
  return (
    m.includes('load failed') ||
    m.includes('failed to fetch') ||
    m.includes('network request failed') ||
    m.includes('networkerror') ||
    m.includes('timeout')
  )
}

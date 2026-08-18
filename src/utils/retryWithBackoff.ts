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
 */
export function isTransientNetworkError(err: unknown): boolean {
  const code = (err as { code?: unknown } | null | undefined)?.code
  if (typeof code === 'string' && code !== '') return false
  if (typeof code === 'number') return false

  const m = getErrorMessage(err).toLowerCase()
  return (
    m.includes('load failed') ||
    m.includes('failed to fetch') ||
    m.includes('network request failed') ||
    m.includes('networkerror') ||
    m.includes('timeout')
  )
}

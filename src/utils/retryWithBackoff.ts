/**
 * Retry generico con backoff exponencial para operaciones que pueden fallar
 * transientemente (errores de fetch, network, timeout).
 *
 * Tipico uso: envolver una llamada a supabase.rpc cuando el RPC es idempotente
 * server-side (ej. acepta client_request_id). NO usar para operaciones no
 * idempotentes: el retry duplicaria efectos si la primera request llego al
 * servidor pero la respuesta se perdio.
 */

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
 * NetworkError. NO matchea PostgrestError con codigo semantico (esos vienen
 * con `error.code` y NO se lanzan como Error desde supabase-js).
 */
export function isTransientNetworkError(err: unknown): boolean {
  if (!(err instanceof Error)) return false
  const m = err.message?.toLowerCase() ?? ''
  return (
    m.includes('load failed') ||
    m.includes('failed to fetch') ||
    m.includes('network request failed') ||
    m.includes('networkerror') ||
    m.includes('timeout')
  )
}

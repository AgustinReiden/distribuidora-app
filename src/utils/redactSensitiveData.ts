/**
 * Redacción de campos sensibles en objetos de logging/telemetría.
 *
 * No confundir con `sanitize.ts` (ese es anti-XSS: limpia HTML de strings
 * para render/guardado). Este módulo tapa VALORES enteros de campos que no
 * tienen que salir de la app -- ni a la consola, ni a Sentry.
 *
 * Vive separado de `logger.ts` porque `logger.ts` importa `captureException`/
 * `captureMessage` de `sentry.ts`: si `sentry.ts` importara esto desde
 * `logger.ts` para su propio `beforeSend`, sería un ciclo.
 */

/** Campos que nunca deben salir de la app: ni a la consola, ni a Sentry. */
export const SENSITIVE_FIELDS = [
  'password', 'token', 'api_key', 'apiKey', 'secret', 'credential',
  'authorization', 'auth', 'key', 'cuit', 'dni', 'telefono',
  'direccion', 'email', 'razon_social', 'nombre'
]

/**
 * Redacta recursivamente un objeto/array, reemplazando el VALOR de toda
 * clave sensible por '[REDACTED]' (comparación por substring en minúsculas
 * sobre la clave, así "clienteDireccion" también cae).
 */
export function redactSensitiveFields<T>(data: T): T {
  if (data === null || data === undefined) return data
  if (typeof data !== 'object') return data
  if (Array.isArray(data)) return data.map(redactSensitiveFields) as T

  const redacted: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(data as Record<string, unknown>)) {
    const lowerKey = key.toLowerCase()
    if (SENSITIVE_FIELDS.some(field => lowerKey.includes(field))) {
      redacted[key] = '[REDACTED]'
    } else if (typeof value === 'object' && value !== null) {
      redacted[key] = redactSensitiveFields(value)
    } else {
      redacted[key] = value
    }
  }
  return redacted as T
}

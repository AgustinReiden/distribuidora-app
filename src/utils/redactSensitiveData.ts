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

const REDACTADO = '[REDACTED]'

/** Grupos lógicos de PostgREST (`or`, `and`, `not.or`, `clientes.or`...): llevan columnas y valores adentro. */
const PARAM_LOGICO = /(^|\.)(or|and)$/i

/** Operadores de PostgREST que comparan contra texto tipeado: una búsqueda. */
const OPERADOR_DE_BUSQUEDA = /(^|[.(,])(not\.)?(like|ilike|match|imatch|fts|plfts|phfts|wfts)(\([^)]*\))?\./i

function decodificar(s: string): string {
  try {
    return decodeURIComponent(s.replace(/\+/g, ' '))
  } catch {
    return s
  }
}

function esParamSensible(clave: string, valor: string): boolean {
  const c = clave.toLowerCase()
  if (PARAM_LOGICO.test(c)) return true
  if (SENSITIVE_FIELDS.some(field => c.includes(field.toLowerCase()))) return true
  return OPERADOR_DE_BUSQUEDA.test(valor)
}

function redactarParams(params: string): string {
  return params
    .split('&')
    .map(par => {
      const igual = par.indexOf('=')
      if (igual === -1) return par
      const clave = par.slice(0, igual)
      return esParamSensible(decodificar(clave), decodificar(par.slice(igual + 1)))
        ? `${clave}=${REDACTADO}`
        : par
    })
    .join('&')
}

/**
 * Tapa el VALOR de los parámetros de una URL que pueden llevar datos de un
 * cliente, y deja el resto para poder diagnosticar (tabla, `select`, `order`,
 * `limit`, `id=eq.5`).
 *
 * El caso que lo motivó (#1266): la búsqueda de pedidos arma
 * `or=(nombre_fantasia.ilike.*Juan*,cuit.ilike.*20123*,...)`, y esa URL viajaba
 * entera en los breadcrumbs de fetch de Sentry, en los spans y en el Replay.
 * Se tapa: todo `or`/`and`, todo valor con un operador de búsqueda
 * (`ilike`, `fts`...) y todo parámetro con nombre sensible (`cuit=eq.…`,
 * `nombre_fantasia=…`, `apikey`, el `access_token` del fragmento).
 */
export function redactarUrl(url: string): string {
  const hash = url.indexOf('#')
  const sinFragmento = hash === -1 ? url : url.slice(0, hash)
  const fragmento = hash === -1 ? '' : url.slice(hash + 1)
  const pregunta = sinFragmento.indexOf('?')
  const base = pregunta === -1 ? sinFragmento : sinFragmento.slice(0, pregunta)
  const query = pregunta === -1 ? null : sinFragmento.slice(pregunta + 1)

  let resultado = query === null ? base : `${base}?${redactarParams(query)}`
  if (hash !== -1) resultado += `#${fragmento.includes('=') ? redactarParams(fragmento) : fragmento}`
  return resultado
}

/**
 * Lo mejor que se puede hacer con un texto libre (un mensaje de error, un log):
 * las URLs pasan por `redactarUrl`, y se tapan los CUIT/CUIL, los emails y las
 * corridas de 7 o más dígitos (DNI, teléfono). Un nombre propio no se puede
 * reconocer en texto libre: el que arma mensajes con nombres de clientes (los
 * rechazos del server) se tapa entero en `sentry.ts`.
 */
export function redactarTexto(texto: string): string {
  return texto
    .replace(/https?:\/\/[^\s"'<>]+/g, u => redactarUrl(u))
    .replace(/[^\s@"'<>]+@[^\s@"'<>]+\.[^\s@"'<>]+/g, REDACTADO)
    .replace(/\b\d{2}-\d{8}-\d\b/g, REDACTADO)
    .replace(/\b\d{7,}\b/g, REDACTADO)
}

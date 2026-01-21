/**
 * Logger seguro para la aplicacion
 *
 * Solo muestra logs en desarrollo, nunca en produccion.
 * No loguea datos sensibles (API keys, credenciales, coordenadas exactas, etc.)
 * Errores en produccion se envian a Sentry automaticamente.
 */

// eslint-disable-next-line no-unused-vars
import { captureException, captureMessage, addBreadcrumb } from '../lib/sentry'

const isDevelopment = import.meta.env.DEV || import.meta.env.MODE === 'development'

// Campos que nunca deben loguearse
const SENSITIVE_FIELDS = [
  'password', 'token', 'api_key', 'apiKey', 'secret', 'credential',
  'authorization', 'auth', 'key', 'cuit', 'dni', 'telefono'
]

/**
 * Sanitiza un objeto removiendo campos sensibles
 * @param {any} data - Datos a sanitizar
 * @returns {any} - Datos sanitizados
 */
function sanitize(data) {
  if (data === null || data === undefined) return data
  if (typeof data !== 'object') return data
  if (Array.isArray(data)) return data.map(sanitize)

  const sanitized = {}
  for (const [key, value] of Object.entries(data)) {
    const lowerKey = key.toLowerCase()
    if (SENSITIVE_FIELDS.some(field => lowerKey.includes(field))) {
      sanitized[key] = '[REDACTED]'
    } else if (typeof value === 'object' && value !== null) {
      sanitized[key] = sanitize(value)
    } else {
      sanitized[key] = value
    }
  }
  return sanitized
}

/**
 * Formatea argumentos para logging seguro
 */
function formatArgs(args) {
  return args.map(arg => {
    if (typeof arg === 'object' && arg !== null) {
      return sanitize(arg)
    }
    return arg
  })
}

/**
 * Logger principal
 */
const logger = {
  /**
   * Log informativo (solo en desarrollo)
   */
  info: (...args) => {
    if (isDevelopment) {
      console.log('[INFO]', ...formatArgs(args))
    }
  },

  /**
   * Log de warning (solo en desarrollo)
   */
  warn: (...args) => {
    if (isDevelopment) {
      console.warn('[WARN]', ...formatArgs(args))
    }
  },

  /**
   * Log de error
   * En desarrollo muestra en consola, en produccion envia a Sentry
   */
  error: (...args) => {
    const sanitizedArgs = formatArgs(args)

    if (isDevelopment) {
      console.error('[ERROR]', ...sanitizedArgs)
    }

    // En produccion, enviar a Sentry
    if (!isDevelopment) {
      const firstArg = args[0]
      if (firstArg instanceof Error) {
        captureException(firstArg, {
          extra: { additionalInfo: sanitizedArgs.slice(1) }
        })
      } else {
        captureMessage(String(firstArg), 'error')
      }
    }
  },

  /**
   * Log de debug (solo en desarrollo, mas verbose)
   */
  debug: (...args) => {
    if (isDevelopment && import.meta.env.VITE_DEBUG === 'true') {
      console.log('[DEBUG]', ...formatArgs(args))
    }
  },

  /**
   * Log de performance/timing
   */
  time: (label) => {
    if (isDevelopment) {
      console.time(label)
    }
  },

  timeEnd: (label) => {
    if (isDevelopment) {
      console.timeEnd(label)
    }
  },

  /**
   * Agrupa logs relacionados
   */
  group: (label) => {
    if (isDevelopment) {
      console.group(label)
    }
  },

  groupEnd: () => {
    if (isDevelopment) {
      console.groupEnd()
    }
  }
}

export default logger
export { logger, isDevelopment }

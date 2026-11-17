/**
 * Logger seguro para la aplicacion
 *
 * Solo muestra logs en desarrollo, nunca en produccion.
 * No loguea datos sensibles (API keys, credenciales, coordenadas exactas, etc.)
 * Errores en produccion se envian a Sentry automaticamente.
 */

import { captureException, captureMessage } from '../lib/sentry'
import { redactSensitiveFields, redactarTexto } from './redactSensitiveData'

const isDevelopment = import.meta.env.DEV || import.meta.env.MODE === 'development'

/**
 * Formatea argumentos para logging seguro
 */
function formatArgs(args: unknown[]): unknown[] {
  return args.map(arg => {
    if (typeof arg === 'object' && arg !== null) {
      return redactSensitiveFields(arg)
    }
    return arg
  })
}

/**
 * El `error` que devuelve supabase-js NO es un `Error`: es un objeto plano
 * `{ message, details, hint, code }` (ver `errorDeSupabase`). Para un `logger.error` con uno de
 * esos como argumento, la etiqueta sola no alcanza para diagnosticar (1600-b4).
 */
function esErrorPlano(arg: unknown): arg is { message: string; code?: unknown } {
  return typeof arg === 'object' && arg !== null && !(arg instanceof Error)
    && typeof (arg as { message?: unknown }).message === 'string'
}

/**
 * Del error plano de supabase sale SÓLO el `code` (1600-b4, con la regla de #1266). El `message`,
 * el `details` y el `hint` no viajan: el `details` de un 23505, 23514 o 23502 trae los valores de
 * la fila (nombres, direcciones, CUIT), y un `message` de RAISE puede nombrar un cliente o un
 * producto. El código (42501, PGRST201, 23505) es lo que diagnostica.
 */
function codigoDelErrorPlano(plano: { code?: unknown }): string {
  return typeof plano.code === 'string' && plano.code !== '' ? plano.code : 'sin código'
}

/**
 * Logger principal
 */
const logger = {
  /**
   * Log informativo (solo en desarrollo)
   */
  info: (...args: unknown[]): void => {
    if (isDevelopment) {
      console.log('[INFO]', ...formatArgs(args))
    }
  },

  /**
   * Log de warning (solo en desarrollo)
   */
  warn: (...args: unknown[]): void => {
    if (isDevelopment) {
      console.warn('[WARN]', ...formatArgs(args))
    }
  },

  /**
   * Log de error
   * En desarrollo muestra en consola, en produccion envia a Sentry
   */
  error: (...args: unknown[]): void => {
    const sanitizedArgs = formatArgs(args)

    if (isDevelopment) {
      console.error('[ERROR]', ...sanitizedArgs)
    }

    // En produccion, enviar a Sentry. El primer argumento suele ser una etiqueta
    // fija, pero a veces es un template con datos (#1266): pasa por
    // `redactarTexto` igual que todo lo que sale en `beforeSend`.
    if (!isDevelopment) {
      const mensaje = redactarTexto(String(args[0]))
      const errorIndex = args.findIndex(arg => arg instanceof Error)
      if (errorIndex !== -1) {
        const error = args[errorIndex] as Error
        const resto = sanitizedArgs.filter((_, i) => i !== errorIndex)
        captureException(error, {
          extra: { message: mensaje, additionalInfo: resto }
        })
      } else {
        const planoIndex = args.findIndex(esErrorPlano)
        if (planoIndex !== -1) {
          // Un error plano de supabase: sin esto sólo llegaba la etiqueta a Sentry y se perdía
          // el `code`, que es lo que diagnostica. Se manda como excepción con la etiqueta y el
          // código; el texto del server no viaja (ver `codigoDelErrorPlano`).
          const plano = args[planoIndex] as { code?: unknown }
          const codigo = codigoDelErrorPlano(plano)
          const resto = sanitizedArgs.filter((_, i) => i !== planoIndex)
          captureException(
            new Error(`${mensaje} [${codigo}]`),
            { extra: { message: mensaje, additionalInfo: resto, codigoSupabase: codigo } }
          )
        } else {
          captureMessage(mensaje, 'error')
        }
      }
    }
  },

  /**
   * Log de debug (solo en desarrollo, mas verbose)
   */
  debug: (...args: unknown[]): void => {
    if (isDevelopment && import.meta.env.VITE_DEBUG === 'true') {
      console.log('[DEBUG]', ...formatArgs(args))
    }
  },

  /**
   * Log de performance/timing
   */
  time: (label: string): void => {
    if (isDevelopment) {
      console.time(label)
    }
  },

  timeEnd: (label: string): void => {
    if (isDevelopment) {
      console.timeEnd(label)
    }
  },

  /**
   * Agrupa logs relacionados
   */
  group: (label: string): void => {
    if (isDevelopment) {
      console.group(label)
    }
  },

  groupEnd: (): void => {
    if (isDevelopment) {
      console.groupEnd()
    }
  }
}

export default logger
export { logger, isDevelopment }

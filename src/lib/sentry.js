/**
 * Configuración de Sentry para monitoreo de errores
 *
 * Para activar Sentry en producción:
 * 1. Crear cuenta en https://sentry.io
 * 2. Crear proyecto React
 * 3. Agregar VITE_SENTRY_DSN al archivo .env
 *
 * Variables de entorno requeridas:
 * - VITE_SENTRY_DSN: DSN del proyecto Sentry
 */

import * as Sentry from '@sentry/react'

const SENTRY_DSN = import.meta.env.VITE_SENTRY_DSN
const IS_PRODUCTION = import.meta.env.PROD
const APP_VERSION = import.meta.env.VITE_APP_VERSION || '1.0.0'

/**
 * Inicializa Sentry si está configurado
 */
export function initSentry() {
  // Solo inicializar si hay DSN configurado
  if (!SENTRY_DSN) {
    if (IS_PRODUCTION) {
      console.warn('[Sentry] DSN no configurado. Los errores no se reportarán.')
    }
    return
  }

  Sentry.init({
    dsn: SENTRY_DSN,

    // Identificador de release para source maps
    release: `distribuidora-app@${APP_VERSION}`,

    // Solo capturar errores en producción
    enabled: IS_PRODUCTION,

    // Porcentaje de transacciones a monitorear (performance)
    tracesSampleRate: 0.1, // 10%

    // Porcentaje de sesiones a monitorear (crashes)
    replaysSessionSampleRate: 0.1, // 10%

    // Capturar 100% de sesiones con error
    replaysOnErrorSampleRate: 1.0,

    // Entorno
    environment: IS_PRODUCTION ? 'production' : 'development',

    // Filtrar datos sensibles antes de enviar
    beforeSend(event) {
      // Redactar datos sensibles del usuario
      if (event.user) {
        delete event.user.ip_address
      }

      // Redactar breadcrumbs con datos sensibles
      if (event.breadcrumbs) {
        event.breadcrumbs = event.breadcrumbs.map(crumb => {
          if (crumb.data) {
            // Redactar contraseñas, tokens, etc.
            const sensitiveKeys = ['password', 'token', 'api_key', 'secret', 'cuit', 'dni']
            for (const key of sensitiveKeys) {
              if (crumb.data[key]) {
                crumb.data[key] = '[REDACTED]'
              }
            }
          }
          return crumb
        })
      }

      return event
    },

    // Ignorar ciertos errores comunes
    ignoreErrors: [
      // Errores de red que no son bugs
      'Network Error',
      'Failed to fetch',
      'Load failed',
      // Errores de extensiones del navegador
      'chrome-extension://',
      'moz-extension://',
      // Errores de ResizeObserver (común en React)
      'ResizeObserver loop limit exceeded',
      // Errores de autenticación (esperados)
      'Invalid login credentials',
      'JWT expired'
    ],

    // Integrations
    integrations: [
      Sentry.browserTracingIntegration(),
      Sentry.replayIntegration({
        // Enmascarar inputs de texto
        maskAllText: false,
        maskAllInputs: true,
        // No grabar elementos sensibles
        blockAllMedia: false
      })
    ]
  })

  console.log('[Sentry] Inicializado correctamente')
}

/**
 * Captura una excepción manualmente
 * @param {Error} error - Error a capturar
 * @param {object} context - Contexto adicional
 */
export function captureException(error, context = {}) {
  if (!SENTRY_DSN) {
    console.error('[Error]', error, context)
    return
  }

  Sentry.withScope((scope) => {
    // Agregar contexto extra
    if (context.tags) {
      for (const [key, value] of Object.entries(context.tags)) {
        scope.setTag(key, value)
      }
    }

    if (context.extra) {
      for (const [key, value] of Object.entries(context.extra)) {
        scope.setExtra(key, value)
      }
    }

    if (context.user) {
      scope.setUser(context.user)
    }

    Sentry.captureException(error)
  })
}

/**
 * Captura un mensaje (no error) para logging
 * @param {string} message - Mensaje a capturar
 * @param {'info'|'warning'|'error'} level - Nivel del mensaje
 */
export function captureMessage(message, level = 'info') {
  if (!SENTRY_DSN) {
    console.log(`[${level.toUpperCase()}]`, message)
    return
  }

  Sentry.captureMessage(message, level)
}

/**
 * Configura el usuario actual para contexto
 * @param {object} user - Datos del usuario
 */
export function setUser(user) {
  if (!SENTRY_DSN) return

  Sentry.setUser(user ? {
    id: user.id,
    email: user.email,
    username: user.nombre || user.email
  } : null)
}

/**
 * Agrega un breadcrumb para debugging
 * @param {object} breadcrumb - Breadcrumb data
 */
export function addBreadcrumb(breadcrumb) {
  if (!SENTRY_DSN) return

  Sentry.addBreadcrumb({
    category: breadcrumb.category || 'app',
    message: breadcrumb.message,
    level: breadcrumb.level || 'info',
    data: breadcrumb.data
  })
}

/**
 * Higher-order component para error boundary con Sentry
 */
export const SentryErrorBoundary = Sentry.ErrorBoundary

/**
 * Hook para capturar errores en componentes funcionales
 */
export const useSentryErrorBoundary = () => {
  return {
    captureException,
    captureMessage,
    addBreadcrumb
  }
}

export default {
  init: initSentry,
  captureException,
  captureMessage,
  setUser,
  addBreadcrumb,
  ErrorBoundary: SentryErrorBoundary
}

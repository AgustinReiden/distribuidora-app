/**
 * Configuración de Sentry para monitoreo de errores y performance
 *
 * Para activar Sentry en producción:
 * 1. Crear cuenta en https://sentry.io
 * 2. Crear proyecto React
 * 3. Agregar VITE_SENTRY_DSN al archivo .env
 *
 * Variables de entorno requeridas:
 * - VITE_SENTRY_DSN: DSN del proyecto Sentry
 *
 * Features:
 * - Error tracking con contexto
 * - Performance monitoring (Web Vitals, transacciones)
 * - Session replay para debugging
 * - Alertas configurables
 */

import * as Sentry from '@sentry/react'

const SENTRY_DSN = import.meta.env.VITE_SENTRY_DSN
const IS_PRODUCTION = import.meta.env.PROD
const APP_VERSION = import.meta.env.VITE_APP_VERSION || '1.0.0'

// Umbrales de performance para alertas
const PERFORMANCE_THRESHOLDS = {
  LCP: 2500, // Largest Contentful Paint (ms)
  FID: 100,  // First Input Delay (ms)
  CLS: 0.1,  // Cumulative Layout Shift
  TTFB: 800, // Time to First Byte (ms)
  FCP: 1800  // First Contentful Paint (ms)
}

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
    tracesSampleRate: IS_PRODUCTION ? 0.2 : 1.0, // 20% en prod, 100% en dev

    // Porcentaje de sesiones a monitorear (crashes)
    replaysSessionSampleRate: 0.1, // 10%

    // Capturar 100% de sesiones con error
    replaysOnErrorSampleRate: 1.0,

    // Entorno
    environment: IS_PRODUCTION ? 'production' : 'development',

    // Configuración de profiling para performance
    profilesSampleRate: IS_PRODUCTION ? 0.1 : 0, // 10% en prod

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

    // Filtrar transacciones de performance
    beforeSendTransaction(event) {
      // Ignorar transacciones de health checks
      if (event.transaction?.includes('/health') || event.transaction?.includes('/ping')) {
        return null
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
      'JWT expired',
      // Errores de PWA
      'The operation was aborted',
      'Registration failed - Service Worker'
    ],

    // Integrations
    integrations: [
      // Tracing de navegación y requests
      Sentry.browserTracingIntegration({
        // Rutas de la aplicación
        tracePropagationTargets: ['localhost', /^\//],
        // Capturar interacciones del usuario
        enableInp: true
      }),
      // Replay de sesiones
      Sentry.replayIntegration({
        // Enmascarar inputs de texto
        maskAllText: false,
        maskAllInputs: true,
        // No grabar elementos sensibles
        blockAllMedia: false,
        // Redactar selectores específicos
        block: ['.sensitive-data', '[data-sentry-block]']
      }),
      // Feedback del usuario
      Sentry.feedbackIntegration({
        colorScheme: 'system',
        showBranding: false,
        buttonLabel: 'Reportar problema',
        submitButtonLabel: 'Enviar reporte',
        cancelButtonLabel: 'Cancelar',
        formTitle: 'Reportar un problema',
        messagePlaceholder: 'Describe qué pasó...',
        successMessageText: '¡Gracias por tu reporte!'
      })
    ]
  })

  console.log('[Sentry] Inicializado correctamente')
}

/**
 * Reporta métricas de Web Vitals a Sentry
 * @param {object} metric - Métrica de web-vitals
 */
export function reportWebVital(metric) {
  const { name, value, rating } = metric

  // Agregar como breadcrumb para tracking
  Sentry.addBreadcrumb({
    category: 'web-vital',
    message: `${name}: ${value.toFixed(name === 'CLS' ? 3 : 0)}`,
    level: rating === 'poor' ? 'warning' : 'info',
    data: {
      metric: name,
      value,
      rating,
      page: window.location.pathname
    }
  })

  // Crear alerta si excede el umbral
  const threshold = PERFORMANCE_THRESHOLDS[name]
  if (threshold && value > threshold) {
    Sentry.addBreadcrumb({
      category: 'performance',
      message: `Web Vital ${name} excede umbral: ${value.toFixed(2)} > ${threshold}`,
      level: 'warning',
      data: { metric: name, value, threshold, rating }
    })
  }
}

/**
 * Inicia una transacción de performance personalizada
 * @param {string} name - Nombre de la transacción
 * @param {string} op - Tipo de operación
 */
export function startTransaction(name, op = 'function') {
  return Sentry.startSpan({ name, op }, () => {})
}

/**
 * Mide el tiempo de una operación
 * @param {string} name - Nombre de la medición
 * @param {Function} fn - Función a medir
 */
export async function measureAsync(name, fn) {
  return Sentry.startSpan({ name, op: 'function' }, async () => {
    return await fn()
  })
}

/**
 * Registra una métrica personalizada via breadcrumb
 * @param {string} name - Nombre de la métrica
 * @param {number} value - Valor
 * @param {object} tags - Tags adicionales
 */
export function recordMetric(name, value, tags = {}) {
  Sentry.addBreadcrumb({
    category: 'metric',
    message: `${name}: ${value}`,
    level: 'info',
    data: { name, value, ...tags }
  })
}

/**
 * Incrementa un contador via breadcrumb
 * @param {string} name - Nombre del contador
 * @param {number} value - Valor a incrementar
 * @param {object} tags - Tags adicionales
 */
export function incrementCounter(name, value = 1, tags = {}) {
  Sentry.addBreadcrumb({
    category: 'counter',
    message: `${name}: +${value}`,
    level: 'info',
    data: { name, value, ...tags }
  })
}

/**
 * Registra una distribución via breadcrumb
 * @param {string} name - Nombre
 * @param {number} value - Valor
 * @param {string} unit - Unidad (millisecond, byte, etc.)
 * @param {object} tags - Tags adicionales
 */
export function recordDistribution(name, value, unit = 'millisecond', tags = {}) {
  Sentry.addBreadcrumb({
    category: 'distribution',
    message: `${name}: ${value}${unit}`,
    level: 'info',
    data: { name, value, unit, ...tags }
  })
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

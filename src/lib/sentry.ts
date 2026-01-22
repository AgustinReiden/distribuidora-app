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

// =============================================================================
// TYPE DEFINITIONS
// =============================================================================

/** Web Vital metric names */
export type WebVitalName = 'LCP' | 'FID' | 'CLS' | 'TTFB' | 'FCP' | 'INP'

/** Web Vital rating */
export type WebVitalRating = 'good' | 'needs-improvement' | 'poor'

/** Web Vital metric object from web-vitals library */
export interface WebVitalMetric {
  /** Metric name */
  name: WebVitalName
  /** Metric value */
  value: number
  /** Metric rating based on thresholds */
  rating: WebVitalRating
  /** Unique ID for the metric */
  id?: string
  /** Delta from previous value */
  delta?: number
  /** Navigation type */
  navigationType?: string
}

/** Performance thresholds configuration */
export interface PerformanceThresholds {
  LCP: number
  FID: number
  CLS: number
  TTFB: number
  FCP: number
}

/** User context for Sentry */
export interface SentryUser {
  id?: string
  email?: string
  nombre?: string
  username?: string
  [key: string]: unknown
}

/** Tags for Sentry context */
export interface SentryTags {
  [key: string]: string | number | boolean
}

/** Extra data for Sentry context */
export interface SentryExtra {
  [key: string]: unknown
}

/** Context object for captureException */
export interface CaptureExceptionContext {
  tags?: SentryTags
  extra?: SentryExtra
  user?: SentryUser
}

/** Breadcrumb level */
export type BreadcrumbLevel = 'debug' | 'info' | 'warning' | 'error' | 'fatal'

/** Breadcrumb data */
export interface BreadcrumbData {
  [key: string]: unknown
}

/** Breadcrumb configuration */
export interface SentryBreadcrumb {
  category?: string
  message: string
  level?: BreadcrumbLevel
  data?: BreadcrumbData
}

/** Message level */
export type MessageLevel = 'info' | 'warning' | 'error'

/** Metric tags */
export interface MetricTags {
  [key: string]: string | number | boolean
}

/** Distribution units */
export type DistributionUnit = 'millisecond' | 'second' | 'byte' | 'kilobyte' | 'megabyte' | 'none'

/** Hook return type for useSentryErrorBoundary */
export interface SentryErrorBoundaryHook {
  captureException: (error: Error, context?: CaptureExceptionContext) => void
  captureMessage: (message: string, level?: MessageLevel) => void
  addBreadcrumb: (breadcrumb: SentryBreadcrumb) => void
}

/** Default export interface */
export interface SentryModule {
  init: () => void
  captureException: (error: Error, context?: CaptureExceptionContext) => void
  captureMessage: (message: string, level?: MessageLevel) => void
  setUser: (user: SentryUser | null) => void
  addBreadcrumb: (breadcrumb: SentryBreadcrumb) => void
  ErrorBoundary: typeof Sentry.ErrorBoundary
}

// =============================================================================
// CONSTANTS
// =============================================================================

const SENTRY_DSN: string | undefined = import.meta.env.VITE_SENTRY_DSN
const IS_PRODUCTION: boolean = import.meta.env.PROD
const APP_VERSION: string = import.meta.env.VITE_APP_VERSION || '1.0.0'

// Umbrales de performance para alertas
const PERFORMANCE_THRESHOLDS: PerformanceThresholds = {
  LCP: 2500, // Largest Contentful Paint (ms)
  FID: 100,  // First Input Delay (ms)
  CLS: 0.1,  // Cumulative Layout Shift
  TTFB: 800, // Time to First Byte (ms)
  FCP: 1800  // First Contentful Paint (ms)
}

// =============================================================================
// INITIALIZATION
// =============================================================================

/**
 * Inicializa Sentry si está configurado
 */
export function initSentry(): void {
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

    // Propagation targets for tracing (moved from browserTracingIntegration in Sentry v10)
    tracePropagationTargets: ['localhost', /^\//],

    // Integrations
    integrations: [
      // Tracing de navegación y requests
      Sentry.browserTracingIntegration({
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

// =============================================================================
// WEB VITALS
// =============================================================================

/**
 * Reporta métricas de Web Vitals a Sentry
 * @param metric - Métrica de web-vitals
 */
export function reportWebVital(metric: WebVitalMetric): void {
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
  const threshold = PERFORMANCE_THRESHOLDS[name as keyof PerformanceThresholds]
  if (threshold && value > threshold) {
    Sentry.addBreadcrumb({
      category: 'performance',
      message: `Web Vital ${name} excede umbral: ${value.toFixed(2)} > ${threshold}`,
      level: 'warning',
      data: { metric: name, value, threshold, rating }
    })
  }
}

// =============================================================================
// PERFORMANCE MONITORING
// =============================================================================

/**
 * Inicia una transacción de performance personalizada
 * @param name - Nombre de la transacción
 * @param op - Tipo de operación
 */
export function startTransaction(name: string, op: string = 'function'): void {
  Sentry.startSpan({ name, op }, () => {})
}

/**
 * Mide el tiempo de una operación async
 * @param name - Nombre de la medición
 * @param fn - Función a medir
 * @returns El resultado de la función
 */
export async function measureAsync<T>(name: string, fn: () => Promise<T>): Promise<T> {
  return Sentry.startSpan({ name, op: 'function' }, async () => {
    return await fn()
  })
}

// =============================================================================
// METRICS
// =============================================================================

/**
 * Registra una métrica personalizada via breadcrumb
 * @param name - Nombre de la métrica
 * @param value - Valor
 * @param tags - Tags adicionales
 */
export function recordMetric(name: string, value: number, tags: MetricTags = {}): void {
  Sentry.addBreadcrumb({
    category: 'metric',
    message: `${name}: ${value}`,
    level: 'info',
    data: { name, value, ...tags }
  })
}

/**
 * Incrementa un contador via breadcrumb
 * @param name - Nombre del contador
 * @param value - Valor a incrementar
 * @param tags - Tags adicionales
 */
export function incrementCounter(name: string, value: number = 1, tags: MetricTags = {}): void {
  Sentry.addBreadcrumb({
    category: 'counter',
    message: `${name}: +${value}`,
    level: 'info',
    data: { name, value, ...tags }
  })
}

/**
 * Registra una distribución via breadcrumb
 * @param name - Nombre
 * @param value - Valor
 * @param unit - Unidad (millisecond, byte, etc.)
 * @param tags - Tags adicionales
 */
export function recordDistribution(
  name: string,
  value: number,
  unit: DistributionUnit = 'millisecond',
  tags: MetricTags = {}
): void {
  Sentry.addBreadcrumb({
    category: 'distribution',
    message: `${name}: ${value}${unit}`,
    level: 'info',
    data: { name, value, unit, ...tags }
  })
}

// =============================================================================
// ERROR TRACKING
// =============================================================================

/**
 * Captura una excepción manualmente
 * @param error - Error a capturar
 * @param context - Contexto adicional
 */
export function captureException(error: Error, context: CaptureExceptionContext = {}): void {
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
 * @param message - Mensaje a capturar
 * @param level - Nivel del mensaje
 */
export function captureMessage(message: string, level: MessageLevel = 'info'): void {
  if (!SENTRY_DSN) {
    console.log(`[${level.toUpperCase()}]`, message)
    return
  }

  Sentry.captureMessage(message, level)
}

// =============================================================================
// USER CONTEXT
// =============================================================================

/**
 * Configura el usuario actual para contexto
 * @param user - Datos del usuario
 */
export function setUser(user: SentryUser | null): void {
  if (!SENTRY_DSN) return

  Sentry.setUser(user ? {
    id: user.id,
    email: user.email,
    username: user.nombre || user.email
  } : null)
}

// =============================================================================
// BREADCRUMBS
// =============================================================================

/**
 * Agrega un breadcrumb para debugging
 * @param breadcrumb - Breadcrumb data
 */
export function addBreadcrumb(breadcrumb: SentryBreadcrumb): void {
  if (!SENTRY_DSN) return

  Sentry.addBreadcrumb({
    category: breadcrumb.category || 'app',
    message: breadcrumb.message,
    level: breadcrumb.level || 'info',
    data: breadcrumb.data
  })
}

// =============================================================================
// REACT INTEGRATION
// =============================================================================

/**
 * Higher-order component para error boundary con Sentry
 */
export const SentryErrorBoundary = Sentry.ErrorBoundary

/**
 * Hook para capturar errores en componentes funcionales
 */
export const useSentryErrorBoundary = (): SentryErrorBoundaryHook => {
  return {
    captureException,
    captureMessage,
    addBreadcrumb
  }
}

// =============================================================================
// DEFAULT EXPORT
// =============================================================================

const sentryModule: SentryModule = {
  init: initSentry,
  captureException,
  captureMessage,
  setUser,
  addBreadcrumb,
  ErrorBoundary: SentryErrorBoundary
}

export default sentryModule

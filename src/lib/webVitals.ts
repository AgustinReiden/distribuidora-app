/**
 * Web Vitals - Monitoreo de métricas de rendimiento
 *
 * Captura las Core Web Vitals y las reporta a Sentry y la consola.
 *
 * Métricas monitoreadas:
 * - LCP (Largest Contentful Paint): Tiempo hasta que el contenido principal es visible
 * - FID (First Input Delay): Tiempo hasta que la página responde a interacciones
 * - CLS (Cumulative Layout Shift): Estabilidad visual de la página
 * - FCP (First Contentful Paint): Tiempo hasta el primer contenido
 * - TTFB (Time to First Byte): Tiempo de respuesta del servidor
 * - INP (Interaction to Next Paint): Latencia de interacciones
 */

import { onCLS, onFCP, onLCP, onTTFB, onINP, type Metric } from 'web-vitals'
import { reportWebVital, addBreadcrumb, type WebVitalMetric, type SentryBreadcrumb } from './sentry'

// =============================================================================
// TYPES
// =============================================================================

/** Metric name type */
export type MetricName = 'LCP' | 'CLS' | 'FCP' | 'TTFB' | 'INP';

/** Rating for a metric */
export type MetricRating = 'good' | 'needs-improvement' | 'poor' | 'unknown';

/** Threshold configuration for a metric */
export interface MetricThreshold {
  good: number;
  needsImprovement: number;
}

/** Thresholds map type */
export type ThresholdsMap = Record<MetricName, MetricThreshold>;

/** Enriched metric with additional context */
export interface EnrichedMetric {
  name: string;
  value: number;
  rating: MetricRating;
  id: string;
  navigationType: string | undefined;
  page: string;
  timestamp: number;
}

/** Stored vitals map */
export interface StoredVitals {
  [key: string]: EnrichedMetric;
}

/** Metric summary entry */
export interface MetricSummaryEntry {
  value: number;
  rating: MetricRating;
}

/** Summary of all vitals */
export interface VitalsSummary {
  metrics: Record<string, MetricSummaryEntry>;
  overallRating: MetricRating;
  goodCount: number;
  poorCount: number;
  totalMetrics: number;
}

/** Debugger render result */
export interface DebuggerRenderResult {
  render: () => void;
}

/** Breadcrumb level */
export type BreadcrumbLevel = 'info' | 'warning' | 'error';

// =============================================================================
// CONSTANTS
// =============================================================================

// Umbrales según las recomendaciones de Google (2024)
// FID fue reemplazado por INP como Core Web Vital
const THRESHOLDS: ThresholdsMap = {
  LCP: { good: 2500, needsImprovement: 4000 },
  CLS: { good: 0.1, needsImprovement: 0.25 },
  FCP: { good: 1800, needsImprovement: 3000 },
  TTFB: { good: 800, needsImprovement: 1800 },
  INP: { good: 200, needsImprovement: 500 }
}

// =============================================================================
// FUNCTIONS
// =============================================================================

/**
 * Obtiene el rating de una métrica
 * @param name - Nombre de la métrica
 * @param value - Valor
 * @returns Rating de la métrica
 */
function getRating(name: string, value: number): MetricRating {
  const threshold = THRESHOLDS[name as MetricName]
  if (!threshold) return 'unknown'

  if (value <= threshold.good) return 'good'
  if (value <= threshold.needsImprovement) return 'needs-improvement'
  return 'poor'
}

/**
 * Handler para métricas de Web Vitals
 * @param metric - Métrica reportada
 */
function handleMetric(metric: Metric): void {
  const { name, value, id, navigationType, delta } = metric
  const rating = getRating(name, value)

  // Crear objeto de métrica enriquecido para almacenamiento local
  const enrichedMetric: EnrichedMetric = {
    name,
    value,
    rating,
    id,
    navigationType,
    page: window.location.pathname,
    timestamp: Date.now()
  }

  // Crear objeto compatible con Sentry
  const sentryMetric: WebVitalMetric = {
    name: name as WebVitalMetric['name'],
    value,
    rating: rating as WebVitalMetric['rating'],
    id,
    delta
  }

  // Reportar a Sentry
  reportWebVital(sentryMetric)

  // Log en desarrollo
  if (import.meta.env.DEV) {
    const color = rating === 'good' ? 'green' : rating === 'needs-improvement' ? 'orange' : 'red'
    console.log(
      `%c[Web Vital] ${name}: ${value.toFixed(name === 'CLS' ? 3 : 0)}${name === 'CLS' ? '' : 'ms'} (${rating})`,
      `color: ${color}; font-weight: bold;`
    )
  }

  // Agregar breadcrumb para debugging
  const level: BreadcrumbLevel = rating === 'poor' ? 'warning' : 'info'
  const breadcrumb: SentryBreadcrumb = {
    category: 'web-vital',
    message: `${name}: ${value.toFixed(2)}`,
    level,
    data: { ...enrichedMetric }
  }
  addBreadcrumb(breadcrumb)

  // Almacenar en sessionStorage para dashboard local
  try {
    const stored: StoredVitals = JSON.parse(sessionStorage.getItem('webVitals') || '{}')
    stored[name] = enrichedMetric
    sessionStorage.setItem('webVitals', JSON.stringify(stored))
  } catch {
    // Ignorar errores de storage
  }
}

/**
 * Inicializa el monitoreo de Web Vitals
 */
export function initWebVitals(): void {
  // Core Web Vitals (2024: LCP, CLS, INP)
  onLCP(handleMetric)
  onCLS(handleMetric)
  onINP(handleMetric)

  // Métricas adicionales
  onFCP(handleMetric)
  onTTFB(handleMetric)

  console.log('[Web Vitals] Monitoreo inicializado')
}

/**
 * Obtiene las métricas almacenadas en la sesión
 * @returns Métricas por nombre
 */
export function getStoredVitals(): StoredVitals {
  try {
    return JSON.parse(sessionStorage.getItem('webVitals') || '{}') as StoredVitals
  } catch {
    return {}
  }
}

/**
 * Obtiene un resumen de las métricas
 * @returns Resumen con puntuación general
 */
export function getVitalsSummary(): VitalsSummary {
  const vitals = getStoredVitals()
  const metrics: MetricName[] = ['LCP', 'CLS', 'FCP', 'TTFB', 'INP']

  let goodCount = 0
  let poorCount = 0
  const summary: Record<string, MetricSummaryEntry> = {}

  for (const name of metrics) {
    const metric = vitals[name]
    if (metric) {
      summary[name] = {
        value: metric.value,
        rating: metric.rating
      }
      if (metric.rating === 'good') goodCount++
      if (metric.rating === 'poor') poorCount++
    }
  }

  // Calcular puntuación general
  const totalMetrics = Object.keys(summary).length
  let overallRating: MetricRating = 'unknown'

  if (totalMetrics > 0) {
    if (poorCount === 0 && goodCount === totalMetrics) {
      overallRating = 'good'
    } else if (poorCount > totalMetrics / 2) {
      overallRating = 'poor'
    } else {
      overallRating = 'needs-improvement'
    }
  }

  return {
    metrics: summary,
    overallRating,
    goodCount,
    poorCount,
    totalMetrics
  }
}

/**
 * Componente para mostrar Web Vitals en desarrollo
 * Usa DOM manipulation en lugar de innerHTML por seguridad
 */
export function WebVitalsDebugger(): DebuggerRenderResult | null {
  if (!import.meta.env.DEV) return null

  const vitals = getStoredVitals()

  return {
    render: (): void => {
      const container = document.createElement('div')
      container.id = 'web-vitals-debug'
      container.style.cssText = `
        position: fixed;
        bottom: 80px;
        right: 10px;
        background: rgba(0,0,0,0.8);
        color: white;
        padding: 10px;
        border-radius: 8px;
        font-family: monospace;
        font-size: 12px;
        z-index: 9999;
        max-width: 200px;
      `

      // Título usando DOM seguro
      const title = document.createElement('strong')
      title.textContent = 'Web Vitals'
      container.appendChild(title)
      container.appendChild(document.createElement('br'))

      // Métricas usando DOM seguro
      for (const [name, metric] of Object.entries(vitals)) {
        const typedMetric = metric as EnrichedMetric
        const color = typedMetric.rating === 'good' ? '#4ade80' :
                     typedMetric.rating === 'needs-improvement' ? '#facc15' : '#ef4444'

        const span = document.createElement('span')
        span.style.color = color
        span.textContent = `${name}: ${typedMetric.value.toFixed(name === 'CLS' ? 3 : 0)}`
        container.appendChild(span)
        container.appendChild(document.createElement('br'))
      }

      document.body.appendChild(container)
    }
  }
}

/** Default export with all functions */
export default {
  init: initWebVitals,
  getStoredVitals,
  getVitalsSummary
}

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

import { onCLS, onFCP, onLCP, onTTFB, onINP } from 'web-vitals'
import { reportWebVital, addBreadcrumb } from './sentry'

// Umbrales según las recomendaciones de Google (2024)
// FID fue reemplazado por INP como Core Web Vital
const THRESHOLDS = {
  LCP: { good: 2500, needsImprovement: 4000 },
  CLS: { good: 0.1, needsImprovement: 0.25 },
  FCP: { good: 1800, needsImprovement: 3000 },
  TTFB: { good: 800, needsImprovement: 1800 },
  INP: { good: 200, needsImprovement: 500 }
}

/**
 * Obtiene el rating de una métrica
 * @param {string} name - Nombre de la métrica
 * @param {number} value - Valor
 * @returns {'good'|'needs-improvement'|'poor'}
 */
function getRating(name, value) {
  const threshold = THRESHOLDS[name]
  if (!threshold) return 'unknown'

  if (value <= threshold.good) return 'good'
  if (value <= threshold.needsImprovement) 'needs-improvement'
  return 'poor'
}

/**
 * Handler para métricas de Web Vitals
 * @param {object} metric - Métrica reportada
 */
function handleMetric(metric) {
  const { name, value, id, navigationType } = metric
  const rating = getRating(name, value)

  // Crear objeto de métrica enriquecido
  const enrichedMetric = {
    name,
    value,
    rating,
    id,
    navigationType,
    page: window.location.pathname,
    timestamp: Date.now()
  }

  // Reportar a Sentry
  reportWebVital(enrichedMetric)

  // Log en desarrollo
  if (import.meta.env.DEV) {
    const color = rating === 'good' ? 'green' : rating === 'needs-improvement' ? 'orange' : 'red'
    console.log(
      `%c[Web Vital] ${name}: ${value.toFixed(name === 'CLS' ? 3 : 0)}${name === 'CLS' ? '' : 'ms'} (${rating})`,
      `color: ${color}; font-weight: bold;`
    )
  }

  // Agregar breadcrumb para debugging
  addBreadcrumb({
    category: 'web-vital',
    message: `${name}: ${value.toFixed(2)}`,
    level: rating === 'poor' ? 'warning' : 'info',
    data: enrichedMetric
  })

  // Almacenar en sessionStorage para dashboard local
  try {
    const stored = JSON.parse(sessionStorage.getItem('webVitals') || '{}')
    stored[name] = enrichedMetric
    sessionStorage.setItem('webVitals', JSON.stringify(stored))
  } catch {
    // Ignorar errores de storage
  }
}

/**
 * Inicializa el monitoreo de Web Vitals
 */
export function initWebVitals() {
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
 * @returns {object} Métricas por nombre
 */
export function getStoredVitals() {
  try {
    return JSON.parse(sessionStorage.getItem('webVitals') || '{}')
  } catch {
    return {}
  }
}

/**
 * Obtiene un resumen de las métricas
 * @returns {object} Resumen con puntuación general
 */
export function getVitalsSummary() {
  const vitals = getStoredVitals()
  const metrics = ['LCP', 'CLS', 'FCP', 'TTFB', 'INP']

  let goodCount = 0
  let poorCount = 0
  const summary = {}

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
  let overallRating = 'unknown'

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
 */
export function WebVitalsDebugger() {
  if (!import.meta.env.DEV) return null

  const vitals = getStoredVitals()

  return {
    render: () => {
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

      let html = '<strong>Web Vitals</strong><br>'
      for (const [name, metric] of Object.entries(vitals)) {
        const color = metric.rating === 'good' ? '#4ade80' :
                     metric.rating === 'needs-improvement' ? '#facc15' : '#ef4444'
        html += `<span style="color:${color}">${name}: ${metric.value.toFixed(name === 'CLS' ? 3 : 0)}</span><br>`
      }

      container.innerHTML = html
      document.body.appendChild(container)
    }
  }
}

export default {
  init: initWebVitals,
  getStoredVitals,
  getVitalsSummary
}

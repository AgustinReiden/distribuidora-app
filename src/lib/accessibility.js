/**
 * Accessibility Utilities - Herramientas de accesibilidad WCAG AA
 *
 * Features:
 * - Auditoría automatizada con axe-core (solo desarrollo)
 * - Anuncios para screen readers (aria-live)
 * - Focus management
 * - Detección de preferencias del usuario
 */

// Inicializar axe-core solo en desarrollo
let axeInitialized = false

/**
 * Inicializa axe-core para auditoría de accesibilidad en desarrollo
 */
export async function initAccessibilityAudit() {
  if (import.meta.env.PROD || axeInitialized) return

  try {
    const axe = await import('@axe-core/react')
    const React = await import('react')
    const ReactDOM = await import('react-dom')

    axe.default(React.default, ReactDOM.default, 1000, {
      // Configuración de reglas WCAG AA
      rules: [
        { id: 'color-contrast', enabled: true },
        { id: 'label', enabled: true },
        { id: 'image-alt', enabled: true },
        { id: 'button-name', enabled: true },
        { id: 'link-name', enabled: true },
        { id: 'heading-order', enabled: true },
        { id: 'landmark-one-main', enabled: true },
        { id: 'region', enabled: true },
        { id: 'aria-roles', enabled: true },
        { id: 'tabindex', enabled: true }
      ]
    })

    axeInitialized = true
    console.log('[A11y] Auditoría de accesibilidad activada')
  } catch (error) {
    console.warn('[A11y] No se pudo inicializar axe-core:', error)
  }
}

// =============================================================================
// ARIA LIVE ANNOUNCEMENTS
// =============================================================================

let liveRegion = null

/**
 * Crea o obtiene la región aria-live para anuncios
 */
function getLiveRegion() {
  if (liveRegion && document.body.contains(liveRegion)) {
    return liveRegion
  }

  liveRegion = document.createElement('div')
  liveRegion.id = 'a11y-announcer'
  liveRegion.setAttribute('aria-live', 'polite')
  liveRegion.setAttribute('aria-atomic', 'true')
  liveRegion.setAttribute('role', 'status')
  liveRegion.className = 'sr-only'
  liveRegion.style.cssText = `
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    margin: -1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    white-space: nowrap;
    border: 0;
  `

  document.body.appendChild(liveRegion)
  return liveRegion
}

/**
 * Anuncia un mensaje a lectores de pantalla
 * @param {string} message - Mensaje a anunciar
 * @param {'polite'|'assertive'} priority - Prioridad del anuncio
 */
export function announce(message, priority = 'polite') {
  const region = getLiveRegion()
  region.setAttribute('aria-live', priority)

  // Limpiar y establecer mensaje
  region.textContent = ''

  // Pequeño delay para que el screen reader detecte el cambio
  requestAnimationFrame(() => {
    region.textContent = message
  })

  // Limpiar después de un tiempo
  setTimeout(() => {
    if (region.textContent === message) {
      region.textContent = ''
    }
  }, 5000)
}

/**
 * Anuncia carga completada
 * @param {string} section - Sección que se cargó
 */
export function announceLoaded(section) {
  announce(`${section} cargado correctamente`)
}

/**
 * Anuncia un error
 * @param {string} error - Mensaje de error
 */
export function announceError(error) {
  announce(`Error: ${error}`, 'assertive')
}

/**
 * Anuncia éxito de una acción
 * @param {string} action - Descripción de la acción
 */
export function announceSuccess(action) {
  announce(`${action} completado con éxito`)
}

/**
 * Anuncia navegación a una nueva sección
 * @param {string} section - Nombre de la sección
 */
export function announceNavigation(section) {
  announce(`Navegando a ${section}`)
}

// =============================================================================
// FOCUS MANAGEMENT
// =============================================================================

/**
 * Mueve el foco al contenido principal
 */
export function focusMain() {
  const main = document.querySelector('main, [role="main"], #main-content')
  if (main) {
    main.setAttribute('tabindex', '-1')
    main.focus()
    main.removeAttribute('tabindex')
  }
}

/**
 * Atrapa el foco dentro de un elemento (para modales)
 * @param {HTMLElement} container - Contenedor donde atrapar el foco
 * @returns {Function} Función para liberar el foco
 */
export function trapFocus(container) {
  const focusableElements = container.querySelectorAll(
    'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
  )

  const firstFocusable = focusableElements[0]
  const lastFocusable = focusableElements[focusableElements.length - 1]

  const handleKeydown = (e) => {
    if (e.key !== 'Tab') return

    if (e.shiftKey && document.activeElement === firstFocusable) {
      e.preventDefault()
      lastFocusable?.focus()
    } else if (!e.shiftKey && document.activeElement === lastFocusable) {
      e.preventDefault()
      firstFocusable?.focus()
    }
  }

  container.addEventListener('keydown', handleKeydown)
  firstFocusable?.focus()

  return () => {
    container.removeEventListener('keydown', handleKeydown)
  }
}

/**
 * Restaura el foco a un elemento previo
 * @param {HTMLElement} element - Elemento donde restaurar el foco
 */
export function restoreFocus(element) {
  if (element && typeof element.focus === 'function') {
    element.focus()
  }
}

// =============================================================================
// USER PREFERENCES
// =============================================================================

/**
 * Detecta si el usuario prefiere movimiento reducido
 * @returns {boolean}
 */
export function prefersReducedMotion() {
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

/**
 * Detecta si el usuario prefiere alto contraste
 * @returns {boolean}
 */
export function prefersHighContrast() {
  return window.matchMedia('(prefers-contrast: more)').matches ||
         window.matchMedia('(-ms-high-contrast: active)').matches
}

/**
 * Detecta si el usuario prefiere modo oscuro
 * @returns {boolean}
 */
export function prefersDarkMode() {
  return window.matchMedia('(prefers-color-scheme: dark)').matches
}

/**
 * Escucha cambios en preferencias del usuario
 * @param {string} preference - 'reduced-motion' | 'high-contrast' | 'dark-mode'
 * @param {Function} callback - Función a ejecutar cuando cambia
 * @returns {Function} Función para remover el listener
 */
export function onPreferenceChange(preference, callback) {
  const queries = {
    'reduced-motion': '(prefers-reduced-motion: reduce)',
    'high-contrast': '(prefers-contrast: more)',
    'dark-mode': '(prefers-color-scheme: dark)'
  }

  const query = window.matchMedia(queries[preference])
  const handler = (e) => callback(e.matches)

  query.addEventListener('change', handler)
  return () => query.removeEventListener('change', handler)
}

// =============================================================================
// KEYBOARD NAVIGATION
// =============================================================================

/**
 * Habilita navegación por teclado en una lista
 * @param {HTMLElement} container - Contenedor de la lista
 * @param {string} itemSelector - Selector de items
 * @param {object} options - Opciones de configuración
 */
export function enableListNavigation(container, itemSelector, options = {}) {
  const {
    orientation = 'vertical',
    wrap = true,
    onSelect = () => {}
  } = options

  const getItems = () => Array.from(container.querySelectorAll(itemSelector))

  const handleKeydown = (e) => {
    const items = getItems()
    const currentIndex = items.indexOf(document.activeElement)

    let nextIndex = currentIndex

    const isVertical = orientation === 'vertical'
    const prevKey = isVertical ? 'ArrowUp' : 'ArrowLeft'
    const nextKey = isVertical ? 'ArrowDown' : 'ArrowRight'

    switch (e.key) {
      case prevKey:
        e.preventDefault()
        nextIndex = currentIndex > 0 ? currentIndex - 1 : (wrap ? items.length - 1 : 0)
        break
      case nextKey:
        e.preventDefault()
        nextIndex = currentIndex < items.length - 1 ? currentIndex + 1 : (wrap ? 0 : items.length - 1)
        break
      case 'Home':
        e.preventDefault()
        nextIndex = 0
        break
      case 'End':
        e.preventDefault()
        nextIndex = items.length - 1
        break
      case 'Enter':
      case ' ':
        e.preventDefault()
        onSelect(items[currentIndex], currentIndex)
        return
      default:
        return
    }

    items[nextIndex]?.focus()
  }

  container.addEventListener('keydown', handleKeydown)
  return () => container.removeEventListener('keydown', handleKeydown)
}

// =============================================================================
// UTILITIES
// =============================================================================

/**
 * Genera un ID único para atributos ARIA
 * @param {string} prefix - Prefijo del ID
 * @returns {string}
 */
export function generateId(prefix = 'a11y') {
  return `${prefix}-${Math.random().toString(36).substr(2, 9)}`
}

/**
 * Verifica si un elemento es visible para screen readers
 * @param {HTMLElement} element - Elemento a verificar
 * @returns {boolean}
 */
export function isAccessiblyHidden(element) {
  if (!element) return true

  const style = window.getComputedStyle(element)

  return (
    style.display === 'none' ||
    style.visibility === 'hidden' ||
    element.getAttribute('aria-hidden') === 'true' ||
    element.hidden
  )
}

export default {
  init: initAccessibilityAudit,
  announce,
  announceLoaded,
  announceError,
  announceSuccess,
  announceNavigation,
  focusMain,
  trapFocus,
  restoreFocus,
  prefersReducedMotion,
  prefersHighContrast,
  prefersDarkMode,
  onPreferenceChange,
  enableListNavigation,
  generateId,
  isAccessiblyHidden
}

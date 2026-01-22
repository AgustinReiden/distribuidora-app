/**
 * Accessibility Utilities - Herramientas de accesibilidad WCAG AA
 *
 * Features:
 * - Auditoría automatizada con axe-core (solo desarrollo)
 * - Anuncios para screen readers (aria-live)
 * - Focus management
 * - Detección de preferencias del usuario
 */

// =============================================================================
// TYPE DEFINITIONS
// =============================================================================

/** Priority level for aria-live announcements */
export type AnnouncePriority = 'polite' | 'assertive'

/** User preference types */
export type PreferenceType = 'reduced-motion' | 'high-contrast' | 'dark-mode'

/** Media query mapping for preferences */
export interface PreferenceQueries {
  'reduced-motion': string
  'high-contrast': string
  'dark-mode': string
}

/** Orientation for list navigation */
export type NavigationOrientation = 'vertical' | 'horizontal'

/** Options for list navigation */
export interface ListNavigationOptions {
  /** Navigation orientation (vertical uses up/down, horizontal uses left/right) */
  orientation?: NavigationOrientation
  /** Whether to wrap around when reaching the end */
  wrap?: boolean
  /** Callback when an item is selected (Enter or Space) */
  onSelect?: (element: Element, index: number) => void
}

/** Callback for preference changes */
export type PreferenceChangeCallback = (matches: boolean) => void

/** Cleanup function returned by event listeners */
export type CleanupFunction = () => void

/** Axe-core rule configuration */
export interface AxeRule {
  id: string
  enabled: boolean
}

/** Axe-core configuration options */
export interface AxeConfig {
  rules: AxeRule[]
}

/** Default export interface */
export interface AccessibilityModule {
  init: () => Promise<void>
  announce: (message: string, priority?: AnnouncePriority) => void
  announceLoaded: (section: string) => void
  announceError: (error: string) => void
  announceSuccess: (action: string) => void
  announceNavigation: (section: string) => void
  focusMain: () => void
  trapFocus: (container: HTMLElement) => CleanupFunction
  restoreFocus: (element: HTMLElement | null) => void
  prefersReducedMotion: () => boolean
  prefersHighContrast: () => boolean
  prefersDarkMode: () => boolean
  onPreferenceChange: (preference: PreferenceType, callback: PreferenceChangeCallback) => CleanupFunction
  enableListNavigation: (
    container: HTMLElement,
    itemSelector: string,
    options?: ListNavigationOptions
  ) => CleanupFunction
  generateId: (prefix?: string) => string
  isAccessiblyHidden: (element: HTMLElement | null) => boolean
}

// =============================================================================
// INITIALIZATION
// =============================================================================

// Inicializar axe-core solo en desarrollo
let axeInitialized = false

/**
 * Inicializa axe-core para auditoría de accesibilidad en desarrollo
 */
export async function initAccessibilityAudit(): Promise<void> {
  if (import.meta.env.PROD || axeInitialized) return

  try {
    const axe = await import('@axe-core/react')
    const React = await import('react')
    const ReactDOM = await import('react-dom')

    const config: AxeConfig = {
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
    }

    axe.default(React.default, ReactDOM.default, 1000, config)

    axeInitialized = true
    console.log('[A11y] Auditoría de accesibilidad activada')
  } catch (error) {
    console.warn('[A11y] No se pudo inicializar axe-core:', error)
  }
}

// =============================================================================
// ARIA LIVE ANNOUNCEMENTS
// =============================================================================

let liveRegion: HTMLDivElement | null = null

/**
 * Crea o obtiene la región aria-live para anuncios
 */
function getLiveRegion(): HTMLDivElement {
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
 * @param message - Mensaje a anunciar
 * @param priority - Prioridad del anuncio
 */
export function announce(message: string, priority: AnnouncePriority = 'polite'): void {
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
 * @param section - Sección que se cargó
 */
export function announceLoaded(section: string): void {
  announce(`${section} cargado correctamente`)
}

/**
 * Anuncia un error
 * @param error - Mensaje de error
 */
export function announceError(error: string): void {
  announce(`Error: ${error}`, 'assertive')
}

/**
 * Anuncia éxito de una acción
 * @param action - Descripción de la acción
 */
export function announceSuccess(action: string): void {
  announce(`${action} completado con éxito`)
}

/**
 * Anuncia navegación a una nueva sección
 * @param section - Nombre de la sección
 */
export function announceNavigation(section: string): void {
  announce(`Navegando a ${section}`)
}

// =============================================================================
// FOCUS MANAGEMENT
// =============================================================================

/** Selector for focusable elements */
const FOCUSABLE_SELECTOR = 'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'

/**
 * Mueve el foco al contenido principal
 */
export function focusMain(): void {
  const main = document.querySelector<HTMLElement>('main, [role="main"], #main-content')
  if (main) {
    main.setAttribute('tabindex', '-1')
    main.focus()
    main.removeAttribute('tabindex')
  }
}

/**
 * Atrapa el foco dentro de un elemento (para modales)
 * @param container - Contenedor donde atrapar el foco
 * @returns Función para liberar el foco
 */
export function trapFocus(container: HTMLElement): CleanupFunction {
  const focusableElements = container.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR)

  const firstFocusable = focusableElements[0] as HTMLElement | undefined
  const lastFocusable = focusableElements[focusableElements.length - 1] as HTMLElement | undefined

  const handleKeydown = (e: KeyboardEvent): void => {
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
 * @param element - Elemento donde restaurar el foco
 */
export function restoreFocus(element: HTMLElement | null): void {
  if (element && typeof element.focus === 'function') {
    element.focus()
  }
}

// =============================================================================
// USER PREFERENCES
// =============================================================================

/**
 * Detecta si el usuario prefiere movimiento reducido
 * @returns true si el usuario prefiere movimiento reducido
 */
export function prefersReducedMotion(): boolean {
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

/**
 * Detecta si el usuario prefiere alto contraste
 * @returns true si el usuario prefiere alto contraste
 */
export function prefersHighContrast(): boolean {
  return window.matchMedia('(prefers-contrast: more)').matches ||
         window.matchMedia('(-ms-high-contrast: active)').matches
}

/**
 * Detecta si el usuario prefiere modo oscuro
 * @returns true si el usuario prefiere modo oscuro
 */
export function prefersDarkMode(): boolean {
  return window.matchMedia('(prefers-color-scheme: dark)').matches
}

/**
 * Escucha cambios en preferencias del usuario
 * @param preference - Tipo de preferencia a observar
 * @param callback - Función a ejecutar cuando cambia
 * @returns Función para remover el listener
 */
export function onPreferenceChange(
  preference: PreferenceType,
  callback: PreferenceChangeCallback
): CleanupFunction {
  const queries: PreferenceQueries = {
    'reduced-motion': '(prefers-reduced-motion: reduce)',
    'high-contrast': '(prefers-contrast: more)',
    'dark-mode': '(prefers-color-scheme: dark)'
  }

  const query = window.matchMedia(queries[preference])
  const handler = (e: MediaQueryListEvent): void => callback(e.matches)

  query.addEventListener('change', handler)
  return () => query.removeEventListener('change', handler)
}

// =============================================================================
// KEYBOARD NAVIGATION
// =============================================================================

/**
 * Habilita navegación por teclado en una lista
 * @param container - Contenedor de la lista
 * @param itemSelector - Selector de items
 * @param options - Opciones de configuración
 * @returns Función para deshabilitar la navegación
 */
export function enableListNavigation(
  container: HTMLElement,
  itemSelector: string,
  options: ListNavigationOptions = {}
): CleanupFunction {
  const {
    orientation = 'vertical',
    wrap = true,
    onSelect = () => {}
  } = options

  const getItems = (): HTMLElement[] => Array.from(container.querySelectorAll<HTMLElement>(itemSelector))

  const handleKeydown = (e: KeyboardEvent): void => {
    const items = getItems()
    const currentIndex = items.indexOf(document.activeElement as HTMLElement)

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
 * @param prefix - Prefijo del ID
 * @returns ID único
 */
export function generateId(prefix: string = 'a11y'): string {
  return `${prefix}-${Math.random().toString(36).substr(2, 9)}`
}

/**
 * Verifica si un elemento es visible para screen readers
 * @param element - Elemento a verificar
 * @returns true si el elemento está oculto para screen readers
 */
export function isAccessiblyHidden(element: HTMLElement | null): boolean {
  if (!element) return true

  const style = window.getComputedStyle(element)

  return (
    style.display === 'none' ||
    style.visibility === 'hidden' ||
    element.getAttribute('aria-hidden') === 'true' ||
    element.hidden
  )
}

// =============================================================================
// DEFAULT EXPORT
// =============================================================================

const accessibilityModule: AccessibilityModule = {
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

export default accessibilityModule

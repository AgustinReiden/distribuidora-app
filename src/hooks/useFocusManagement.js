/**
 * Hooks para gestión de foco y navegación por teclado
 *
 * Mejora la accesibilidad de formularios y modales:
 * - Auto-focus en primer campo
 * - Navegación con Enter entre campos
 * - Submit con Ctrl+Enter o Cmd+Enter
 * - Gestión de foco en errores
 */
import { useEffect, useRef, useCallback } from 'react'

/**
 * Selectores de elementos focalizables
 */
const FOCUSABLE_SELECTORS = [
  'input:not([disabled]):not([type="hidden"])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  'button:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
  'a[href]'
].join(', ')

/**
 * Hook para auto-focus en el primer campo de un formulario
 *
 * @param {object} options - Opciones
 * @param {boolean} options.enabled - Si está habilitado (default: true)
 * @param {number} options.delay - Delay antes de hacer focus (default: 100ms)
 * @param {string} options.selector - Selector CSS del elemento a enfocar
 * @returns {React.RefObject} Ref para el contenedor del formulario
 *
 * @example
 * function MyModal() {
 *   const formRef = useAutoFocus();
 *   return <form ref={formRef}>...</form>;
 * }
 */
export function useAutoFocus({ enabled = true, delay = 100, selector } = {}) {
  const containerRef = useRef(null)

  useEffect(() => {
    if (!enabled || !containerRef.current) return

    const timer = setTimeout(() => {
      const container = containerRef.current
      if (!container) return

      // Buscar elemento específico o primer campo focusable
      const target = selector
        ? container.querySelector(selector)
        : container.querySelector('input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled])')

      if (target && typeof target.focus === 'function') {
        target.focus()
        // Si es input de texto, seleccionar contenido
        if (target.tagName === 'INPUT' && target.type !== 'checkbox' && target.type !== 'radio') {
          target.select?.()
        }
      }
    }, delay)

    return () => clearTimeout(timer)
  }, [enabled, delay, selector])

  return containerRef
}

/**
 * Hook para navegar entre campos con Enter
 *
 * @param {object} options - Opciones
 * @param {boolean} options.enabled - Si está habilitado (default: true)
 * @param {function} options.onSubmit - Callback al llegar al último campo
 * @param {boolean} options.submitOnLastField - Si hacer submit al presionar Enter en último campo
 * @returns {React.RefObject} Ref para el contenedor del formulario
 *
 * @example
 * function MyForm({ onSubmit }) {
 *   const formRef = useEnterNavigation({
 *     onSubmit: (e) => onSubmit(formData)
 *   });
 *   return <form ref={formRef}>...</form>;
 * }
 */
export function useEnterNavigation({ enabled = true, onSubmit, submitOnLastField = true } = {}) {
  const containerRef = useRef(null)

  useEffect(() => {
    if (!enabled || !containerRef.current) return

    const container = containerRef.current

    const handleKeyDown = (e) => {
      // Solo manejar Enter (no en textareas donde Enter es válido)
      if (e.key !== 'Enter' || e.target.tagName === 'TEXTAREA') return

      // No interceptar si es un botón (deja que haga su acción)
      if (e.target.tagName === 'BUTTON') return

      // Prevenir submit por defecto del form
      e.preventDefault()

      // Obtener todos los campos focalizables
      const focusableElements = Array.from(
        container.querySelectorAll('input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled])')
      )

      const currentIndex = focusableElements.indexOf(e.target)

      if (currentIndex === -1) return

      // Si es el último campo
      if (currentIndex === focusableElements.length - 1) {
        if (submitOnLastField && onSubmit) {
          onSubmit(e)
        }
        return
      }

      // Mover al siguiente campo
      const nextElement = focusableElements[currentIndex + 1]
      if (nextElement) {
        nextElement.focus()
        if (nextElement.tagName === 'INPUT' && nextElement.type !== 'checkbox' && nextElement.type !== 'radio') {
          nextElement.select?.()
        }
      }
    }

    container.addEventListener('keydown', handleKeyDown)
    return () => container.removeEventListener('keydown', handleKeyDown)
  }, [enabled, onSubmit, submitOnLastField])

  return containerRef
}

/**
 * Hook para submit con Ctrl/Cmd + Enter
 *
 * @param {function} onSubmit - Callback al hacer submit
 * @param {object} options - Opciones
 * @param {boolean} options.enabled - Si está habilitado (default: true)
 * @returns {React.RefObject} Ref para el contenedor del formulario
 */
export function useKeyboardSubmit(onSubmit, { enabled = true } = {}) {
  const containerRef = useRef(null)

  useEffect(() => {
    if (!enabled || !containerRef.current || !onSubmit) return

    const container = containerRef.current

    const handleKeyDown = (e) => {
      // Ctrl+Enter o Cmd+Enter
      if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
        e.preventDefault()
        onSubmit(e)
      }
    }

    container.addEventListener('keydown', handleKeyDown)
    return () => container.removeEventListener('keydown', handleKeyDown)
  }, [enabled, onSubmit])

  return containerRef
}

/**
 * Hook combinado para formularios con todas las funcionalidades
 *
 * @param {object} options - Opciones
 * @param {function} options.onSubmit - Callback de submit
 * @param {boolean} options.autoFocus - Hacer auto-focus (default: true)
 * @param {boolean} options.enterNavigation - Navegar con Enter (default: true)
 * @param {boolean} options.keyboardSubmit - Submit con Ctrl+Enter (default: true)
 * @returns {React.RefObject} Ref para el formulario
 *
 * @example
 * function MyForm({ onSubmit }) {
 *   const formRef = useFormKeyboard({ onSubmit });
 *   return <form ref={formRef}>...</form>;
 * }
 */
export function useFormKeyboard({
  onSubmit,
  autoFocus = true,
  enterNavigation = true,
  keyboardSubmit = true
} = {}) {
  const containerRef = useRef(null)

  // Auto-focus
  useEffect(() => {
    if (!autoFocus || !containerRef.current) return

    const timer = setTimeout(() => {
      const container = containerRef.current
      if (!container) return

      const target = container.querySelector(
        'input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled])'
      )

      if (target && typeof target.focus === 'function') {
        target.focus()
        if (target.tagName === 'INPUT' && target.type !== 'checkbox' && target.type !== 'radio') {
          target.select?.()
        }
      }
    }, 100)

    return () => clearTimeout(timer)
  }, [autoFocus])

  // Keyboard handlers
  useEffect(() => {
    if (!containerRef.current) return
    if (!enterNavigation && !keyboardSubmit) return

    const container = containerRef.current

    const handleKeyDown = (e) => {
      // Ctrl/Cmd + Enter para submit
      if (keyboardSubmit && e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
        e.preventDefault()
        onSubmit?.(e)
        return
      }

      // Enter navigation
      if (enterNavigation && e.key === 'Enter') {
        if (e.target.tagName === 'TEXTAREA' || e.target.tagName === 'BUTTON') return

        e.preventDefault()

        const focusableElements = Array.from(
          container.querySelectorAll('input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled])')
        )

        const currentIndex = focusableElements.indexOf(e.target)
        if (currentIndex === -1) return

        if (currentIndex === focusableElements.length - 1) {
          onSubmit?.(e)
          return
        }

        const nextElement = focusableElements[currentIndex + 1]
        if (nextElement) {
          nextElement.focus()
          if (nextElement.tagName === 'INPUT' && nextElement.type !== 'checkbox' && nextElement.type !== 'radio') {
            nextElement.select?.()
          }
        }
      }
    }

    container.addEventListener('keydown', handleKeyDown)
    return () => container.removeEventListener('keydown', handleKeyDown)
  }, [enterNavigation, keyboardSubmit, onSubmit])

  return containerRef
}

/**
 * Hook para enfocar el primer campo con error
 *
 * @param {object} errors - Objeto de errores del formulario
 * @param {object} options - Opciones
 * @param {boolean} options.enabled - Si está habilitado (default: true)
 * @returns {React.RefObject} Ref para el contenedor del formulario
 *
 * @example
 * function MyForm({ errors }) {
 *   const formRef = useFocusOnError(errors);
 *   return <form ref={formRef}>...</form>;
 * }
 */
export function useFocusOnError(errors, { enabled = true } = {}) {
  const containerRef = useRef(null)
  const prevErrorsRef = useRef(errors)

  useEffect(() => {
    if (!enabled || !containerRef.current || !errors) return

    // Solo actuar si hay nuevos errores
    const hasNewErrors = Object.keys(errors).length > 0 &&
      JSON.stringify(errors) !== JSON.stringify(prevErrorsRef.current)

    prevErrorsRef.current = errors

    if (!hasNewErrors) return

    // Encontrar el primer campo con error
    const firstErrorKey = Object.keys(errors)[0]
    if (!firstErrorKey) return

    const container = containerRef.current
    const errorField = container.querySelector(
      `[name="${firstErrorKey}"], #${firstErrorKey}, [data-field="${firstErrorKey}"]`
    )

    if (errorField && typeof errorField.focus === 'function') {
      errorField.focus()
      errorField.scrollIntoView?.({ behavior: 'smooth', block: 'center' })
    }
  }, [errors, enabled])

  return containerRef
}

/**
 * Función utilitaria para obtener elementos focalizables
 *
 * @param {HTMLElement} container - Contenedor donde buscar
 * @returns {HTMLElement[]} Array de elementos focalizables
 */
export function getFocusableElements(container) {
  if (!container) return []
  return Array.from(container.querySelectorAll(FOCUSABLE_SELECTORS))
}

/**
 * Función utilitaria para trap focus dentro de un contenedor
 *
 * @param {HTMLElement} container - Contenedor donde atrapar el foco
 * @returns {function} Función para remover el trap
 */
export function trapFocus(container) {
  if (!container) return () => {}

  const focusableElements = getFocusableElements(container)
  const firstElement = focusableElements[0]
  const lastElement = focusableElements[focusableElements.length - 1]

  const handleKeyDown = (e) => {
    if (e.key !== 'Tab') return

    if (e.shiftKey) {
      // Shift + Tab: si estamos en el primer elemento, ir al último
      if (document.activeElement === firstElement) {
        e.preventDefault()
        lastElement?.focus()
      }
    } else {
      // Tab: si estamos en el último elemento, ir al primero
      if (document.activeElement === lastElement) {
        e.preventDefault()
        firstElement?.focus()
      }
    }
  }

  container.addEventListener('keydown', handleKeyDown)

  // Focus primer elemento
  firstElement?.focus()

  return () => container.removeEventListener('keydown', handleKeyDown)
}

export default {
  useAutoFocus,
  useEnterNavigation,
  useKeyboardSubmit,
  useFormKeyboard,
  useFocusOnError,
  getFocusableElements,
  trapFocus
}

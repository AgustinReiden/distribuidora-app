/**
 * Hooks para gestión de foco y navegación por teclado
 *
 * Mejora la accesibilidad de formularios y modales:
 * - Auto-focus en primer campo
 * - Navegación con Enter entre campos
 * - Submit con Ctrl+Enter o Cmd+Enter
 * - Gestión de foco en errores
 */
import { useEffect, useRef, type RefObject } from 'react'

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
 * Elemento focusable del DOM
 */
type FocusableElement = HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement | HTMLButtonElement | HTMLAnchorElement

/**
 * Elemento de formulario que puede ser enfocado
 */
type FormElement = HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement

/**
 * Opciones para useAutoFocus
 */
export interface UseAutoFocusOptions {
  /** Si está habilitado (default: true) */
  enabled?: boolean
  /** Delay antes de hacer focus (default: 100ms) */
  delay?: number
  /** Selector CSS del elemento a enfocar */
  selector?: string
}

/**
 * Hook para auto-focus en el primer campo de un formulario
 *
 * @param options - Opciones
 * @returns Ref para el contenedor del formulario
 *
 * @example
 * function MyModal() {
 *   const formRef = useAutoFocus();
 *   return <form ref={formRef}>...</form>;
 * }
 */
export function useAutoFocus<T extends HTMLElement = HTMLDivElement>(
  options: UseAutoFocusOptions = {}
): RefObject<T | null> {
  const { enabled = true, delay = 100, selector } = options
  const containerRef = useRef<T>(null)

  useEffect(() => {
    if (!enabled || !containerRef.current) return

    const timer = setTimeout(() => {
      const container = containerRef.current
      if (!container) return

      // Buscar elemento específico o primer campo focusable
      const target = selector
        ? container.querySelector<FocusableElement>(selector)
        : container.querySelector<FormElement>('input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled])')

      if (target && typeof target.focus === 'function') {
        target.focus()
        // Si es input de texto, seleccionar contenido
        if (target.tagName === 'INPUT') {
          const input = target as HTMLInputElement
          if (input.type !== 'checkbox' && input.type !== 'radio') {
            input.select?.()
          }
        }
      }
    }, delay)

    return () => clearTimeout(timer)
  }, [enabled, delay, selector])

  return containerRef
}

/**
 * Opciones para useEnterNavigation
 */
export interface UseEnterNavigationOptions {
  /** Si está habilitado (default: true) */
  enabled?: boolean
  /** Callback al llegar al último campo */
  onSubmit?: (e: KeyboardEvent) => void
  /** Si hacer submit al presionar Enter en último campo */
  submitOnLastField?: boolean
}

/**
 * Hook para navegar entre campos con Enter
 *
 * @param options - Opciones
 * @returns Ref para el contenedor del formulario
 *
 * @example
 * function MyForm({ onSubmit }) {
 *   const formRef = useEnterNavigation({
 *     onSubmit: (e) => onSubmit(formData)
 *   });
 *   return <form ref={formRef}>...</form>;
 * }
 */
export function useEnterNavigation<T extends HTMLElement = HTMLDivElement>(
  options: UseEnterNavigationOptions = {}
): RefObject<T | null> {
  const { enabled = true, onSubmit, submitOnLastField = true } = options
  const containerRef = useRef<T>(null)

  useEffect(() => {
    if (!enabled || !containerRef.current) return

    const container = containerRef.current

    const handleKeyDown = (e: KeyboardEvent): void => {
      // Solo manejar Enter (no en textareas donde Enter es válido)
      const target = e.target as HTMLElement
      if (e.key !== 'Enter' || target.tagName === 'TEXTAREA') return

      // No interceptar si es un botón (deja que haga su acción)
      if (target.tagName === 'BUTTON') return

      // Prevenir submit por defecto del form
      e.preventDefault()

      // Obtener todos los campos focalizables
      const focusableElements = Array.from(
        container.querySelectorAll<FormElement>('input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled])')
      )

      const currentIndex = focusableElements.indexOf(target as FormElement)

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
        if (nextElement.tagName === 'INPUT') {
          const input = nextElement as HTMLInputElement
          if (input.type !== 'checkbox' && input.type !== 'radio') {
            input.select?.()
          }
        }
      }
    }

    container.addEventListener('keydown', handleKeyDown)
    return () => container.removeEventListener('keydown', handleKeyDown)
  }, [enabled, onSubmit, submitOnLastField])

  return containerRef
}

/**
 * Opciones para useKeyboardSubmit
 */
export interface UseKeyboardSubmitOptions {
  /** Si está habilitado (default: true) */
  enabled?: boolean
}

/**
 * Hook para submit con Ctrl/Cmd + Enter
 *
 * @param onSubmit - Callback al hacer submit
 * @param options - Opciones
 * @returns Ref para el contenedor del formulario
 */
export function useKeyboardSubmit<T extends HTMLElement = HTMLDivElement>(
  onSubmit: ((e: KeyboardEvent) => void) | undefined,
  options: UseKeyboardSubmitOptions = {}
): RefObject<T | null> {
  const { enabled = true } = options
  const containerRef = useRef<T>(null)

  useEffect(() => {
    if (!enabled || !containerRef.current || !onSubmit) return

    const container = containerRef.current

    const handleKeyDown = (e: KeyboardEvent): void => {
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
 * Opciones para useFormKeyboard
 */
export interface UseFormKeyboardOptions {
  /** Callback de submit */
  onSubmit?: (e: KeyboardEvent) => void
  /** Hacer auto-focus (default: true) */
  autoFocus?: boolean
  /** Navegar con Enter (default: true) */
  enterNavigation?: boolean
  /** Submit con Ctrl+Enter (default: true) */
  keyboardSubmit?: boolean
}

/**
 * Hook combinado para formularios con todas las funcionalidades
 *
 * @param options - Opciones
 * @returns Ref para el formulario
 *
 * @example
 * function MyForm({ onSubmit }) {
 *   const formRef = useFormKeyboard({ onSubmit });
 *   return <form ref={formRef}>...</form>;
 * }
 */
export function useFormKeyboard<T extends HTMLElement = HTMLDivElement>(
  options: UseFormKeyboardOptions = {}
): RefObject<T | null> {
  const {
    onSubmit,
    autoFocus = true,
    enterNavigation = true,
    keyboardSubmit = true
  } = options

  const containerRef = useRef<T>(null)

  // Auto-focus
  useEffect(() => {
    if (!autoFocus || !containerRef.current) return

    const timer = setTimeout(() => {
      const container = containerRef.current
      if (!container) return

      const target = container.querySelector<FormElement>(
        'input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled])'
      )

      if (target && typeof target.focus === 'function') {
        target.focus()
        if (target.tagName === 'INPUT') {
          const input = target as HTMLInputElement
          if (input.type !== 'checkbox' && input.type !== 'radio') {
            input.select?.()
          }
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

    const handleKeyDown = (e: KeyboardEvent): void => {
      const target = e.target as HTMLElement

      // Ctrl/Cmd + Enter para submit
      if (keyboardSubmit && e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
        e.preventDefault()
        onSubmit?.(e)
        return
      }

      // Enter navigation
      if (enterNavigation && e.key === 'Enter') {
        if (target.tagName === 'TEXTAREA' || target.tagName === 'BUTTON') return

        e.preventDefault()

        const focusableElements = Array.from(
          container.querySelectorAll<FormElement>('input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled])')
        )

        const currentIndex = focusableElements.indexOf(target as FormElement)
        if (currentIndex === -1) return

        if (currentIndex === focusableElements.length - 1) {
          onSubmit?.(e)
          return
        }

        const nextElement = focusableElements[currentIndex + 1]
        if (nextElement) {
          nextElement.focus()
          if (nextElement.tagName === 'INPUT') {
            const input = nextElement as HTMLInputElement
            if (input.type !== 'checkbox' && input.type !== 'radio') {
              input.select?.()
            }
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
 * Objeto de errores de formulario
 */
export type FormErrors = Record<string, string | undefined>

/**
 * Opciones para useFocusOnError
 */
export interface UseFocusOnErrorOptions {
  /** Si está habilitado (default: true) */
  enabled?: boolean
}

/**
 * Hook para enfocar el primer campo con error
 *
 * @param errors - Objeto de errores del formulario
 * @param options - Opciones
 * @returns Ref para el contenedor del formulario
 *
 * @example
 * function MyForm({ errors }) {
 *   const formRef = useFocusOnError(errors);
 *   return <form ref={formRef}>...</form>;
 * }
 */
export function useFocusOnError<T extends HTMLElement = HTMLDivElement>(
  errors: FormErrors | null | undefined,
  options: UseFocusOnErrorOptions = {}
): RefObject<T | null> {
  const { enabled = true } = options
  const containerRef = useRef<T>(null)
  const prevErrorsRef = useRef<FormErrors | null | undefined>(errors)

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
    const errorField = container.querySelector<FocusableElement>(
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
 * @param container - Contenedor donde buscar
 * @returns Array de elementos focalizables
 */
export function getFocusableElements(container: HTMLElement | null): FocusableElement[] {
  if (!container) return []
  return Array.from(container.querySelectorAll<FocusableElement>(FOCUSABLE_SELECTORS))
}

/**
 * Función utilitaria para trap focus dentro de un contenedor
 *
 * @param container - Contenedor donde atrapar el foco
 * @returns Función para remover el trap
 */
export function trapFocus(container: HTMLElement | null): () => void {
  if (!container) return () => {}

  const focusableElements = getFocusableElements(container)
  const firstElement = focusableElements[0]
  const lastElement = focusableElements[focusableElements.length - 1]

  const handleKeyDown = (e: KeyboardEvent): void => {
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

/**
 * Exportación por defecto con todos los hooks y utilidades
 */
export default {
  useAutoFocus,
  useEnterNavigation,
  useKeyboardSubmit,
  useFormKeyboard,
  useFocusOnError,
  getFocusableElements,
  trapFocus
}

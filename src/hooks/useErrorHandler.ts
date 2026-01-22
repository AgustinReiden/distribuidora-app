/**
 * Hooks para manejo de errores
 *
 * useErrorHandler: Hook para lanzar errores que serán capturados por el boundary más cercano
 * useAsyncWithErrorBoundary: Hook para manejar operaciones asíncronas con soporte de error boundary
 */

import { useState, useCallback } from 'react'
import { categorizeError } from '../utils/errorUtils'
import { addBreadcrumb } from '../lib/sentry'

// =============================================================================
// TYPES
// =============================================================================

/** Return type for useErrorHandler */
export interface UseErrorHandlerReturn {
  handleError: (err: Error | unknown) => void;
  resetError: () => void;
}

/** Options for useAsyncWithErrorBoundary */
export interface AsyncWithErrorBoundaryOptions {
  throwToErrorBoundary?: boolean;
}

/** State for useAsyncWithErrorBoundary */
export interface AsyncState<T> {
  data: T | null;
  loading: boolean;
  error: Error | null;
}

/** Return type for useAsyncWithErrorBoundary */
export interface UseAsyncWithErrorBoundaryReturn<T, TArgs extends unknown[]> extends AsyncState<T> {
  execute: (...args: TArgs) => Promise<T>;
}

// =============================================================================
// HOOKS
// =============================================================================

/**
 * Hook para lanzar errores que serán capturados por el boundary más cercano
 * Mejorado con categorización y manejo de errores asíncronos
 */
export function useErrorHandler(): UseErrorHandlerReturn {
  const [error, setError] = useState<Error | null>(null)

  if (error) {
    throw error
  }

  const handleError = useCallback((err: Error | unknown): void => {
    // Categorizar el error para logging
    const errorObj = err instanceof Error ? err : new Error(String(err))
    const category = categorizeError(errorObj)
    addBreadcrumb({
      category: 'error-handler',
      message: `Error caught: ${category}`,
      level: 'error',
      data: { message: errorObj.message }
    })
    setError(errorObj)
  }, [])

  const resetError = useCallback((): void => {
    setError(null)
  }, [])

  return { handleError, resetError }
}

/**
 * Hook para manejar operaciones asíncronas con soporte de error boundary
 * @param asyncFn - Función asíncrona a ejecutar
 * @param options - Opciones
 */
export function useAsyncWithErrorBoundary<T, TArgs extends unknown[]>(
  asyncFn: (...args: TArgs) => Promise<T>,
  options: AsyncWithErrorBoundaryOptions = {}
): UseAsyncWithErrorBoundaryReturn<T, TArgs> {
  const { handleError } = useErrorHandler()
  const [state, setState] = useState<AsyncState<T>>({
    data: null,
    loading: false,
    error: null
  })

  const execute = useCallback(async (...args: TArgs): Promise<T> => {
    setState(prev => ({ ...prev, loading: true, error: null }))

    try {
      const result = await asyncFn(...args)
      setState({ data: result, loading: false, error: null })
      return result
    } catch (err: unknown) {
      const errorObj = err instanceof Error ? err : new Error(String(err))
      setState(prev => ({ ...prev, loading: false, error: errorObj }))

      if (options.throwToErrorBoundary) {
        handleError(errorObj)
      }

      throw errorObj
    }
  }, [asyncFn, handleError, options.throwToErrorBoundary])

  return { ...state, execute }
}

export default useErrorHandler

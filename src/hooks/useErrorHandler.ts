/**
 * Hooks para manejo de errores
 *
 * useErrorHandler: Hook para lanzar errores que serán capturados por el boundary más cercano
 * useAsyncWithErrorBoundary: Hook para manejar operaciones asíncronas con soporte de error boundary
 */

import { useState, useCallback } from 'react'
import { categorizeError } from '../utils/errorUtils'
import { addBreadcrumb } from '../lib/sentry'

/**
 * Hook para lanzar errores que serán capturados por el boundary más cercano
 * Mejorado con categorización y manejo de errores asíncronos
 */
export function useErrorHandler() {
  const [error, setError] = useState(null)

  if (error) {
    throw error
  }

  const handleError = useCallback((err) => {
    // Categorizar el error para logging
    const category = categorizeError(err)
    addBreadcrumb({
      category: 'error-handler',
      message: `Error caught: ${category}`,
      level: 'error',
      data: { message: err?.message }
    })
    setError(err)
  }, [])

  const resetError = useCallback(() => {
    setError(null)
  }, [])

  return { handleError, resetError }
}

/**
 * Hook para manejar operaciones asíncronas con soporte de error boundary
 * @param {Function} asyncFn - Función asíncrona a ejecutar
 * @param {Object} options - Opciones
 */
export function useAsyncWithErrorBoundary(asyncFn, options = {}) {
  const { handleError } = useErrorHandler()
  const [state, setState] = useState({
    data: null,
    loading: false,
    error: null
  })

  const execute = useCallback(async (...args) => {
    setState(prev => ({ ...prev, loading: true, error: null }))

    try {
      const result = await asyncFn(...args)
      setState({ data: result, loading: false, error: null })
      return result
    } catch (err) {
      setState(prev => ({ ...prev, loading: false, error: err }))

      if (options.throwToErrorBoundary) {
        handleError(err)
      }

      throw err
    }
  }, [asyncFn, handleError, options.throwToErrorBoundary])

  return { ...state, execute }
}

export default useErrorHandler

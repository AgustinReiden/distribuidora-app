import { useState, useCallback } from 'react'

/**
 * Hook para validación de formularios con Zod
 * @param {import('zod').ZodSchema} schema - Schema de Zod para validar
 * @returns {Object} Objeto con funciones y estado de validación
 */
export function useZodValidation(schema) {
  const [errors, setErrors] = useState({})
  const [hasAttemptedSubmit, setHasAttemptedSubmit] = useState(false)

  /**
   * Valida todos los datos contra el schema
   * @param {Object} data - Datos a validar
   * @returns {{ success: boolean, data?: Object, errors?: Object }}
   */
  const validate = useCallback((data) => {
    setHasAttemptedSubmit(true)
    const result = schema.safeParse(data)

    if (result.success) {
      setErrors({})
      return { success: true, data: result.data }
    }

    // Convertir errores de Zod a objeto con paths como keys
    const newErrors = {}
    const issues = result.error.issues || result.error.errors || []
    for (const issue of issues) {
      const path = issue.path.join('.')
      if (!newErrors[path]) {
        newErrors[path] = issue.message
      }
    }

    setErrors(newErrors)
    return { success: false, errors: newErrors }
  }, [schema])

  /**
   * Valida un campo específico
   * @param {string} field - Nombre del campo
   * @param {any} value - Valor a validar
   * @returns {string|null} Mensaje de error o null si es válido
   */
  const validateField = useCallback((field, value) => {
    if (!hasAttemptedSubmit) return null

    const fieldSchema = schema.shape?.[field]
    if (!fieldSchema) return null

    const result = fieldSchema.safeParse(value)
    if (result.success) {
      setErrors(prev => {
        const newErrors = { ...prev }
        delete newErrors[field]
        return newErrors
      })
      return null
    }

    const errorMsg = result.error.issues?.[0]?.message || result.error.errors?.[0]?.message || 'Error de validación'
    setErrors(prev => ({ ...prev, [field]: errorMsg }))
    return errorMsg
  }, [schema, hasAttemptedSubmit])

  /**
   * Limpia un error específico
   * @param {string} field - Nombre del campo
   */
  const clearFieldError = useCallback((field) => {
    setErrors(prev => {
      const newErrors = { ...prev }
      delete newErrors[field]
      return newErrors
    })
  }, [])

  /**
   * Limpia todos los errores
   */
  const clearErrors = useCallback(() => {
    setErrors({})
    setHasAttemptedSubmit(false)
  }, [])

  /**
   * Obtiene el primer error
   * @returns {string|null}
   */
  const getFirstError = useCallback(() => {
    const firstKey = Object.keys(errors)[0]
    return firstKey ? errors[firstKey] : null
  }, [errors])

  /**
   * Genera props de accesibilidad ARIA para un campo
   * @param {string} field - Nombre del campo
   * @param {boolean} required - Si el campo es requerido
   * @returns {object} Props ARIA para el input
   */
  const getAriaProps = useCallback((field, required = false) => {
    const error = errors[field]
    const errorId = `error-${field}`

    return {
      'aria-invalid': error ? 'true' : undefined,
      'aria-required': required ? 'true' : undefined,
      'aria-describedby': error ? errorId : undefined
    }
  }, [errors])

  /**
   * Genera props para el mensaje de error
   * @param {string} field - Nombre del campo
   * @returns {object} Props para el elemento de error
   */
  const getErrorMessageProps = useCallback((field) => {
    return {
      id: `error-${field}`,
      role: 'alert',
      'aria-live': 'polite'
    }
  }, [])

  return {
    errors,
    hasAttemptedSubmit,
    validate,
    validateField,
    clearFieldError,
    clearErrors,
    getFirstError,
    hasErrors: Object.keys(errors).length > 0,
    // Helpers de accesibilidad
    getAriaProps,
    getErrorMessageProps
  }
}

export default useZodValidation

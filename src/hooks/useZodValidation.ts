import { useState, useCallback } from 'react'
import type { ZodSchema, ZodObject, ZodRawShape } from 'zod'

/** Tipo de errores del formulario */
export type ValidationErrors = Record<string, string>

/** Props ARIA para accesibilidad */
export interface AriaProps {
  'aria-invalid'?: 'true' | undefined;
  'aria-required'?: 'true' | undefined;
  'aria-describedby'?: string | undefined;
}

/** Props para mensaje de error */
export interface ErrorMessageProps {
  id: string;
  role: 'alert';
  'aria-live': 'polite';
}

/** Resultado de validación exitosa */
export interface ValidationSuccess<T> {
  success: true;
  data: T;
  errors?: never;
}

/** Resultado de validación fallida */
export interface ValidationFailure {
  success: false;
  data?: never;
  errors: ValidationErrors;
}

/** Resultado de validación */
export type ValidationResult<T> = ValidationSuccess<T> | ValidationFailure

/** Return type del hook */
export interface UseZodValidationReturn<T> {
  errors: ValidationErrors;
  hasAttemptedSubmit: boolean;
  validate: (data: unknown) => ValidationResult<T>;
  validateField: (field: string, value: unknown) => string | null;
  clearFieldError: (field: string) => void;
  clearErrors: () => void;
  getFirstError: () => string | null;
  hasErrors: boolean;
  getAriaProps: (field: string, required?: boolean) => AriaProps;
  getErrorMessageProps: (field: string) => ErrorMessageProps;
}

/**
 * Hook para validación de formularios con Zod
 * @param schema - Schema de Zod para validar
 * @returns Objeto con funciones y estado de validación
 */
export function useZodValidation<T = unknown>(schema: ZodSchema<T>): UseZodValidationReturn<T> {
  const [errors, setErrors] = useState<ValidationErrors>({})
  const [hasAttemptedSubmit, setHasAttemptedSubmit] = useState(false)

  /**
   * Valida todos los datos contra el schema
   */
  const validate = useCallback((data: unknown): ValidationResult<T> => {
    setHasAttemptedSubmit(true)
    const result = schema.safeParse(data)

    if (result.success) {
      setErrors({})
      return { success: true, data: result.data }
    }

    // Convertir errores de Zod a objeto con paths como keys
    const newErrors: ValidationErrors = {}
    const issues = result.error.issues || []
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
   */
  const validateField = useCallback((field: string, value: unknown): string | null => {
    if (!hasAttemptedSubmit) return null

    const zodObject = schema as ZodObject<ZodRawShape>
    const fieldSchema = zodObject.shape?.[field]
    if (!fieldSchema) return null

    const result = (fieldSchema as ZodSchema).safeParse(value)
    if (result.success) {
      setErrors(prev => {
        const newErrors = { ...prev }
        delete newErrors[field]
        return newErrors
      })
      return null
    }

    const errorMsg = result.error.issues?.[0]?.message || 'Error de validación'
    setErrors(prev => ({ ...prev, [field]: errorMsg }))
    return errorMsg
  }, [schema, hasAttemptedSubmit])

  /**
   * Limpia un error específico
   */
  const clearFieldError = useCallback((field: string): void => {
    setErrors(prev => {
      const newErrors = { ...prev }
      delete newErrors[field]
      return newErrors
    })
  }, [])

  /**
   * Limpia todos los errores
   */
  const clearErrors = useCallback((): void => {
    setErrors({})
    setHasAttemptedSubmit(false)
  }, [])

  /**
   * Obtiene el primer error
   */
  const getFirstError = useCallback((): string | null => {
    const firstKey = Object.keys(errors)[0]
    return firstKey ? errors[firstKey] : null
  }, [errors])

  /**
   * Genera props de accesibilidad ARIA para un campo
   */
  const getAriaProps = useCallback((field: string, required = false): AriaProps => {
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
   */
  const getErrorMessageProps = useCallback((field: string): ErrorMessageProps => {
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
    getAriaProps,
    getErrorMessageProps
  }
}

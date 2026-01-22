/**
 * FormField - Componente de campo de formulario accesible
 *
 * Implementa WCAG 2.1:
 * - aria-invalid para campos con error
 * - aria-describedby para vincular mensajes de error
 * - aria-required para campos obligatorios
 * - Labels asociados correctamente con htmlFor
 */
import { useId, ReactNode, ReactElement, isValidElement, cloneElement } from 'react'

export interface FormFieldProps {
  /** Etiqueta del campo */
  label: string;
  /** Mensaje de error */
  error?: string;
  /** Si el campo es obligatorio */
  required?: boolean;
  /** Texto de ayuda */
  hint?: string;
  /** Input/Select/Textarea */
  children: ReactNode;
  /** Clases adicionales */
  className?: string;
}

export function FormField({
  label,
  error,
  required = false,
  hint,
  children,
  className = ''
}: FormFieldProps): ReactElement {
  const id = useId()
  const inputId = `field-${id}`
  const errorId = `error-${id}`
  const hintId = `hint-${id}`

  // Construir aria-describedby
  const describedByIds: string[] = []
  if (error) describedByIds.push(errorId)
  if (hint) describedByIds.push(hintId)
  const ariaDescribedBy = describedByIds.length > 0 ? describedByIds.join(' ') : undefined

  // Clone and enhance children with accessibility props
  const enhancedChildren = isValidElement(children)
    ? cloneElement(children as ReactElement<{ id?: string; className?: string; 'aria-invalid'?: string; 'aria-required'?: string; 'aria-describedby'?: string }>, {
        id: inputId,
        'aria-invalid': error ? 'true' : undefined,
        'aria-required': required ? 'true' : undefined,
        'aria-describedby': ariaDescribedBy,
        className: `${(children.props as { className?: string }).className || ''} ${
          error
            ? 'border-red-500 dark:border-red-400 bg-red-50 dark:bg-red-900/20 focus:ring-red-500'
            : ''
        }`
      })
    : children

  return (
    <div className={`form-field ${className}`}>
      <label
        htmlFor={inputId}
        className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
      >
        {label}
        {required && <span className="text-red-500 ml-1" aria-hidden="true">*</span>}
      </label>

      {/* Render enhanced children */}
      {enhancedChildren}

      {/* Texto de ayuda */}
      {hint && !error && (
        <p
          id={hintId}
          className="mt-1 text-sm text-gray-500 dark:text-gray-400"
        >
          {hint}
        </p>
      )}

      {/* Mensaje de error */}
      {error && (
        <p
          id={errorId}
          role="alert"
          className="mt-1 text-sm text-red-600 dark:text-red-400 flex items-center gap-1"
        >
          <svg
            className="w-4 h-4 flex-shrink-0"
            fill="currentColor"
            viewBox="0 0 20 20"
            aria-hidden="true"
          >
            <path
              fillRule="evenodd"
              d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7 4a1 1 0 11-2 0 1 1 0 012 0zm-1-9a1 1 0 00-1 1v4a1 1 0 102 0V6a1 1 0 00-1-1z"
              clipRule="evenodd"
            />
          </svg>
          {error}
        </p>
      )}
    </div>
  )
}

export default FormField

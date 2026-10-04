/**
 * FormField - Componente de campo de formulario accesible
 *
 * Implementa WCAG 2.1:
 * - aria-invalid para campos con error
 * - aria-describedby para vincular mensajes de error
 * - aria-required para campos obligatorios
 * - Labels asociados correctamente con htmlFor
 *
 * Qué hace con lo que el hijo ya trae (#777). FormField clona el hijo, pero no
 * le pisa lo que él declaró:
 * - `id`: si el hijo ya tiene uno, ése es el id del campo y el `htmlFor` del
 *   label apunta a él. Sin id propio se genera uno (`field-…`).
 * - `aria-describedby`: se SUMAN las referencias del hint y del error a las del
 *   hijo (las del hijo primero), separadas por espacio y sin repetir.
 * - `aria-invalid` y `aria-required`: los pone FormField (según `error` y
 *   `required`), salvo que el hijo los traiga explícitos: ahí gana el del hijo,
 *   también si es `false`.
 * - `className`: se fusiona (la del hijo, más los estilos de error si hay error).
 *
 * FormField clona UN solo hijo y el id/aria van a ese hijo. Un input envuelto en
 * un div con ícono o sufijo no es candidato: el id caería en el div, no en el
 * input (ver ModalActualizacionMasivaPrecios).
 */
import { useId, ReactNode, ReactElement, AriaAttributes, isValidElement, cloneElement } from 'react'

/** Props que FormField lee y/o inyecta en el hijo. */
interface PropsDelCampo {
  id?: string;
  className?: string;
  'aria-invalid'?: AriaAttributes['aria-invalid'];
  'aria-required'?: AriaAttributes['aria-required'];
  'aria-describedby'?: string;
  inputMode?: string;
}

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
  /**
   * Pista de teclado móvil (se propaga al input hijo).
   * Útil para que Android/iOS muestren el teclado correcto en
   * campos numéricos, de teléfono, email, etc.
   */
  inputMode?: 'none' | 'text' | 'tel' | 'url' | 'email' | 'numeric' | 'decimal' | 'search';
}

export function FormField({
  label,
  error,
  required = false,
  hint,
  children,
  className = '',
  inputMode
}: FormFieldProps): ReactElement {
  const id = useId()
  const hijo = isValidElement<PropsDelCampo>(children) ? children : null
  const propsHijo: PropsDelCampo = hijo?.props ?? {}

  // El id propio del hijo manda; el label lo usa en htmlFor.
  const inputId = propsHijo.id || `field-${id}`
  const errorId = `error-${id}`
  const hintId = `hint-${id}`

  // aria-describedby: lo del hijo + error + hint, sin repetir (el Set conserva el orden).
  const describedByIds = new Set<string>(
    (propsHijo['aria-describedby'] ?? '').split(/\s+/).filter(Boolean)
  )
  if (error) describedByIds.add(errorId)
  if (hint) describedByIds.add(hintId)
  const ariaDescribedBy = describedByIds.size > 0 ? [...describedByIds].join(' ') : undefined

  // aria-invalid / aria-required: si el hijo los trae explícitos, ganan los suyos.
  const ariaInvalid = propsHijo['aria-invalid'] !== undefined
    ? propsHijo['aria-invalid']
    : error ? 'true' : undefined
  const ariaRequired = propsHijo['aria-required'] !== undefined
    ? propsHijo['aria-required']
    : required ? 'true' : undefined

  // Clone and enhance children with accessibility props
  const enhancedChildren = hijo
    ? cloneElement(hijo, {
        id: inputId,
        'aria-invalid': ariaInvalid,
        'aria-required': ariaRequired,
        'aria-describedby': ariaDescribedBy,
        ...(inputMode ? { inputMode } : {}),
        className: `${propsHijo.className || ''} ${
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

/**
 * NumberInput - Campo numérico controlado con mejor UX de edición.
 *
 * Reemplaza al patrón habitual `<input type="number"
 * onChange={e => setX(parseInt(e.target.value) || 0)} />`, que tiene dos
 * molestias:
 *  - El campo NUNCA puede quedar vacío: al borrar el `0` vuelve a `0` al
 *    instante, así que para reemplazarlo terminás tipeando delante/detrás y
 *    queda "010", "0500", etc. (el "0 adelante").
 *  - No se puede escribir un número de una; invita a usar los spinners.
 *
 * Mantiene un borrador (string) interno mientras el input está enfocado, de
 * modo que el campo puede quedar vacío o parcial ("12,") mientras se edita.
 * Al confirmar (blur / Enter) parsea, clampa a [min, max] y normaliza.
 *
 * Usa `type="text"` + `inputMode` a propósito: el `type="number"` es lo que
 * impide controlar el string vacío y los ceros a la izquierda. Con `text`
 * controlamos el valor y igual sale el teclado numérico en mobile.
 */
import {
  useState,
  useRef,
  InputHTMLAttributes,
  ChangeEvent,
  FocusEvent,
  KeyboardEvent,
  ReactElement,
} from 'react'
import { parsePrecio } from '../../utils/calculations'

type InheritedInputProps = Omit<
  InputHTMLAttributes<HTMLInputElement>,
  'value' | 'onChange' | 'type' | 'inputMode' | 'min' | 'max'
>

export interface NumberInputProps extends InheritedInputProps {
  /** Valor numérico confirmado (lo que vive en el state del padre). */
  value: number;
  /** Se llama con el número confirmado (blur/Enter, o en vivo si commitOnChange). */
  onChange: (value: number) => void;
  /** Solo enteros (sin separador decimal). */
  integer?: boolean;
  /** Mínimo; se clampa al confirmar. */
  min?: number;
  /** Máximo; se clampa al confirmar. */
  max?: number;
  /** Qué número confirmar si el campo queda vacío. Default: `min ?? 0`. */
  emptyValue?: number;
  /** Si true, además confirma en vivo por cada tecla con un número válido. */
  commitOnChange?: boolean;
  /** Selecciona el contenido al enfocar (tipear reemplaza). Default true. */
  selectOnFocus?: boolean;
}

export function NumberInput({
  value,
  onChange,
  integer = false,
  min,
  max,
  emptyValue,
  commitOnChange = false,
  selectOnFocus = true,
  onFocus,
  onBlur,
  onKeyDown,
  ...rest
}: NumberInputProps): ReactElement {
  // draft === null  -> mostrar el valor canónico del padre.
  // draft === '...' -> el usuario está editando (puede ser '' o parcial).
  const [draft, setDraft] = useState<string | null>(null)
  const inputRef = useRef<HTMLInputElement>(null)

  /** Limpia el string a un numérico tipeable (sin forzar a número todavía). */
  const sanitize = (raw: string): string => {
    if (integer) {
      // Solo dígitos. Quitar ceros a la izquierda: "007" -> "7", "0" -> "0".
      return raw.replace(/[^\d]/g, '').replace(/^0+(?=\d)/, '')
    }
    // Decimal: dígitos + un único separador ("," o ".").
    let s = raw.replace(/[^\d.,]/g, '')
    const sep = s.search(/[.,]/)
    if (sep !== -1) {
      s = s.slice(0, sep + 1) + s.slice(sep + 1).replace(/[.,]/g, '')
    }
    // Quitar ceros a la izquierda salvo el que precede al separador ("0,5").
    return s.replace(/^0+(?=\d)/, '')
  }

  /** Parsea el borrador a número, o null si está vacío/inválido. */
  const toNumber = (raw: string): number | null => {
    const t = raw.trim()
    if (t === '') return null
    const n = integer ? parseInt(t, 10) : parsePrecio(t)
    return Number.isFinite(n) ? n : null
  }

  const clamp = (n: number): number => {
    let v = n
    if (typeof min === 'number') v = Math.max(min, v)
    if (typeof max === 'number') v = Math.min(max, v)
    return integer ? Math.round(v) : v
  }

  const handleChange = (e: ChangeEvent<HTMLInputElement>): void => {
    const next = sanitize(e.target.value)
    setDraft(next)
    if (commitOnChange) {
      // En vivo mandamos el número crudo (como hacía el parseInt anterior);
      // el clamp/normalización quedan para el blur. El vacío NO empuja 0:
      // se mantiene el último valor y el campo se ve vacío.
      const n = toNumber(next)
      if (n !== null) onChange(n)
    }
  }

  const commit = (): void => {
    if (draft === null) return
    const parsed = toNumber(draft)
    const final = clamp(parsed ?? emptyValue ?? min ?? 0)
    setDraft(null)
    onChange(final)
  }

  const handleBlur = (e: FocusEvent<HTMLInputElement>): void => {
    commit()
    onBlur?.(e)
  }

  const handleFocus = (e: FocusEvent<HTMLInputElement>): void => {
    if (selectOnFocus) e.target.select()
    onFocus?.(e)
  }

  const handleKeyDown = (e: KeyboardEvent<HTMLInputElement>): void => {
    if (e.key === 'Enter') {
      commit()
      inputRef.current?.blur()
    }
    onKeyDown?.(e)
  }

  const display = draft !== null
    ? draft
    : (Number.isFinite(value) ? String(value) : '')

  return (
    <input
      {...rest}
      ref={inputRef}
      type="text"
      inputMode={integer ? 'numeric' : 'decimal'}
      value={display}
      onChange={handleChange}
      onFocus={handleFocus}
      onBlur={handleBlur}
      onKeyDown={handleKeyDown}
    />
  )
}

export default NumberInput

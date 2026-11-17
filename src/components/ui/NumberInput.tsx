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
 *
 * Al tipear, el punto y la coma son decimales (la tecla del punto se ve como
 * coma) y el punto de miles lo pone el campo (D17, #1560): «150000» se ve
 * «150.000», y «1.250» tipeado se ve «1,250» y es uno coma veinticinco. Lo
 * pegado se lee como se muestra la plata («1.250,50» es mil doscientos
 * cincuenta y cincuenta). Lo que no se entiende («1,000,50») queda a la vista
 * en rojo y no se confirma: el campo no lo guarda como otro número. Con
 * `sinMiles` (porcentajes, litros) no hay miles: la tecla del punto es coma y
 * nada más.
 */
import {
  useState,
  useRef,
  useLayoutEffect,
  InputHTMLAttributes,
  ChangeEvent,
  FocusEvent,
  KeyboardEvent,
  ReactElement,
} from 'react'
import { numeroEditable, redondear } from '../../utils/calculations'
import {
  NUMERO_ILEGIBLE,
  formatearTecleo,
  leerDecimalSinMiles,
  leerEntero,
  leerNumero,
  numeroConMiles,
  teclearNumero,
} from '../../utils/normalizarNumero'

type InheritedInputProps = Omit<
  InputHTMLAttributes<HTMLInputElement>,
  'value' | 'onChange' | 'type' | 'inputMode' | 'min' | 'max'
>

export interface NumberInputProps extends InheritedInputProps {
  /** Valor numérico confirmado (lo que vive en el state del padre). `null` = campo vacío. */
  value: number | null;
  /** Se llama con el número confirmado (blur/Enter, o en vivo si commitOnChange). */
  onChange: (value: number) => void;
  /** Solo enteros (sin separador decimal). */
  integer?: boolean;
  /**
   * Sin miles: el punto y la coma son decimales («12.125» → 12,13). Para lo que no es plata y no
   * llega a mil, como un porcentaje. Sin esto, «12.125» se lee doce mil ciento veinticinco (#1560).
   */
  sinMiles?: boolean;
  /** Mínimo; se clampa al confirmar. */
  min?: number;
  /** Máximo; se clampa al confirmar. */
  max?: number;
  /** Qué número confirmar si el campo queda vacío. Default: `min ?? 0`. */
  emptyValue?: number;
  /**
   * Para un campo donde vacío no es un número (L3, #1603: el stock mínimo vacío
   * usa el de siempre, y 0 apaga la alerta): si está, confirmar el campo vacío la
   * llama en vez de confirmar `emptyValue`.
   */
  onVaciar?: () => void;
  /** Si true, además confirma en vivo por cada tecla con un número válido. */
  commitOnChange?: boolean;
  /** Selecciona el contenido al enfocar (tipear reemplaza). Default true. */
  selectOnFocus?: boolean;
}

export function NumberInput({
  value,
  onChange,
  integer = false,
  sinMiles = false,
  min,
  max,
  emptyValue,
  onVaciar,
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
  // Al poner o quitar un punto de miles, React deja el cursor al final: se repone.
  const cursor = useRef<number | null>(null)
  useLayoutEffect(() => {
    const input = inputRef.current
    if (cursor.current !== null && input && document.activeElement === input) {
      input.setSelectionRange(cursor.current, cursor.current)
    }
    cursor.current = null
  })

  /** Sin miles (`sinMiles`): dígitos y un solo separador, el decimal; sin ceros adelante («0,5» queda). */
  const sanitizeSinMiles = (raw: string): string => {
    let s = raw.replace(/[^\d.,]/g, '')
    const sep = s.search(/[.,]/)
    if (sep !== -1) s = s.slice(0, sep + 1) + s.slice(sep + 1).replace(/[.,]/g, '')
    return s.replace(/^0+(?=\d)/, '')
  }

  /** Parsea el borrador a número, o null si está vacío/inválido. */
  const toNumber = (raw: string): number | null => {
    const t = raw.trim()
    if (t === '') return null
    // Un entero con los puntos de miles del campo («1.500»); con coma no es una cantidad.
    if (integer) return leerEntero(t)
    const n = sinMiles ? leerDecimalSinMiles(t) : leerNumero(t)
    return n === null ? null : redondear(n, 2)
  }

  /** Escrito y no se entiende: se muestra en rojo y no se confirma. */
  const ilegible = (raw: string | null): boolean => raw !== null && raw.trim() !== '' && toNumber(raw) === null

  const clamp = (n: number): number => {
    let v = n
    if (typeof min === 'number') v = Math.max(min, v)
    if (typeof max === 'number') v = Math.min(max, v)
    return integer ? Math.round(v) : v
  }

  const handleChange = (e: ChangeEvent<HTMLInputElement>): void => {
    const crudo = e.target.value
    let next: string
    if (sinMiles) {
      const tecleado = teclearNumero(display, crudo)
      if (tecleado !== crudo) cursor.current = e.target.selectionStart
      next = sanitizeSinMiles(tecleado)
    } else {
      const direccion = (e.nativeEvent as InputEvent).inputType === 'deleteContentForward' ? 'adelante' : 'atras'
      const r = formatearTecleo(display, crudo, e.target.selectionStart ?? crudo.length, { direccion })
      cursor.current = r.cursor
      next = r.texto
    }
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
    // Lo que no se entiende no se confirma (ni como vacío): queda a la vista para corregirlo.
    if (ilegible(draft)) return
    const parsed = toNumber(draft)
    setDraft(null)
    if (parsed === null && onVaciar) {
      onVaciar()
      return
    }
    onChange(clamp(parsed ?? emptyValue ?? min ?? 0))
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

  // El valor del padre se muestra con coma decimal y, salvo `sinMiles`, con los miles («1.500,5»).
  // Con coma, «1,5» con dos ceros más sigue siendo uno y medio (#1560).
  const display = draft !== null ? draft : sinMiles ? numeroEditable(value) : numeroConMiles(value)
  const invalido = ilegible(draft)

  return (
    <input
      {...rest}
      ref={inputRef}
      type="text"
      inputMode={integer ? 'numeric' : 'decimal'}
      aria-invalid={invalido ? true : rest['aria-invalid']}
      title={invalido ? NUMERO_ILEGIBLE : rest.title}
      className={invalido ? `${rest.className ?? ''} border-red-500 ring-1 ring-red-500` : rest.className}
      value={display}
      onChange={handleChange}
      onFocus={handleFocus}
      onBlur={handleBlur}
      onKeyDown={handleKeyDown}
    />
  )
}

export default NumberInput

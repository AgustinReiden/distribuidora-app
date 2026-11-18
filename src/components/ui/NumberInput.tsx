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
 * Al confirmar (blur / Enter) parsea y normaliza; lo que queda fuera de [min, max] no se recorta
 * (ver abajo).
 *
 * Usa `type="text"` + `inputMode` a propósito: el `type="number"` es lo que
 * impide controlar el string vacío y los ceros a la izquierda. Con `text`
 * controlamos el valor y igual sale el teclado numérico en mobile.
 *
 * Al tipear, el punto y la coma son decimales (la tecla del punto se ve como
 * coma) y el punto de miles lo pone el campo (D17, #1560): «150000» se ve
 * «150.000», y «1.250» tipeado se ve «1,250» y es uno coma veinticinco. Lo
 * pegado se lee como se muestra la plata («1.250,50» es mil doscientos
 * cincuenta y cincuenta). Con `sinMiles` (porcentajes, litros) no hay miles:
 * la tecla del punto es coma y nada más.
 *
 * Lo que no se entiende («1,000,50», un negativo) queda en rojo con el motivo
 * escrito debajo y no se le manda al padre. Al salir del campo vuelve al valor
 * del padre, con un aviso a la vista: lo que se ve es siempre lo que se guarda
 * (H1 de la lente de #1644). `onValidez` le avisa al padre mientras tanto.
 *
 * Lo mismo con un número fuera de su límite (B23 de #1603, decisión del dueño del 18/11: «Que
 * quede en rojo y no guarde»): bajo `min`, sobre `max`, o vacío en un campo obligatorio, queda en
 * rojo con su motivo (`motivoMin`, `motivoMax`, `motivoVacio`, que dicen el dato del que depende el
 * límite) y no se le manda al padre. Nada se recorta ni se completa en silencio. Un campo con un
 * `min` mayor que 0 y sin `emptyValue` es obligatorio; con `emptyValue` es opcional, y vacío vale
 * eso, que el campo muestra en gris si no tiene otro `placeholder`.
 */
import {
  useState,
  useRef,
  useLayoutEffect,
  useEffect,
  useId,
  InputHTMLAttributes,
  ChangeEvent,
  FocusEvent,
  KeyboardEvent,
  ReactElement,
} from 'react'
import { numeroEditable, redondear } from '../../utils/calculations'
import { useAnotarIlegible } from '../../hooks/useRegistroIlegibles'
import { esPegado } from '../../hooks/useTecleoNumero'
import { CLASES_AVISO_DECIMALES, avisoPlataDecimalesDeMas } from '../../utils/avisoDecimales'
import {
  MENSAJE_ENTERO_CON_COMA,
  MENSAJE_NEGATIVO,
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
  /** Mínimo: menos queda en rojo con `motivoMin` (nunca se sube solo). */
  min?: number;
  /** Máximo: más queda en rojo con `motivoMax` (nunca se recorta solo). */
  max?: number;
  /** Por qué no puede ser menos que `min`, con el dato del que depende («El mínimo de venta es 6»). */
  motivoMin?: string;
  /** Por qué no puede ser más que `max`, con el dato del que depende («Quedan 5 para devolver»). */
  motivoMax?: string;
  /**
   * Qué número vale el campo vacío (un campo opcional; se muestra en gris). Sin esto, vacío vale 0,
   * salvo con un `min` mayor que 0 o un `motivoVacio`: entonces el campo es obligatorio y vacío queda
   * en rojo.
   */
  emptyValue?: number;
  /** El motivo de un campo obligatorio vacío («Poné una cantidad»). Si está, el campo es obligatorio. */
  motivoVacio?: string;
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
  /**
   * Cuántos decimales guarda (por defecto 2: la plata, al centavo). Más decimales tipeados se guardan
   * redondeados, con un aviso amarillo arriba del campo que dice qué se guarda (decisión del dueño,
   * 17/11). No aplica a `integer` ni a `sinMiles`.
   */
  decimales?: number;
  /**
   * Se llama con `false` cuando lo escrito no se entiende (el campo está en rojo y el padre tiene
   * el valor de antes) y con `true` cuando vuelve a entenderse. Para deshabilitar Guardar.
   */
  onValidez?: (valido: boolean) => void;
}

/** El rojo le gana a las clases del campo: el borde oscuro, el anillo del foco y los de color. */
const CLASES_ILEGIBLE = '!border-red-500 dark:!border-red-500 !ring-1 !ring-red-500 focus:!ring-2 focus:!ring-red-500'

export function NumberInput({
  value,
  onChange,
  integer = false,
  sinMiles = false,
  min,
  max,
  motivoMin,
  motivoMax,
  emptyValue,
  motivoVacio,
  onVaciar,
  commitOnChange = false,
  selectOnFocus = true,
  decimales = 2,
  onValidez,
  onFocus,
  onBlur,
  onKeyDown,
  ...rest
}: NumberInputProps): ReactElement {
  // draft === null  -> mostrar el valor canónico del padre.
  // draft === '...' -> el usuario está editando (puede ser '' o parcial).
  const [draft, setDraft] = useState<string | null>(null)
  // Lo que se avisa después de volver al valor del padre por algo que no se entendía.
  const [aviso, setAviso] = useState<string | null>(null)
  // El aviso amarillo de los decimales de más (sólo lo TIPEADO: no lo precargado ni lo pegado), que
  // queda a la vista al salir del campo hasta que el valor cambie.
  const [avisoGuardado, setAvisoGuardado] = useState<string | null>(null)
  const [pegado, setPegado] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)
  const idMensaje = useId()
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
    const n = integer ? leerEntero(t) : sinMiles ? leerDecimalSinMiles(t) : leerNumero(t)
    // Este campo no lleva negativos: un «-50» pegado no le llega al padre (H4).
    if (n === null || n < 0) return null
    return integer ? n : redondear(n, decimales)
  }

  /** Un límite como se ve en el campo («1.500», o «12,5» sin miles). */
  const mostrar = (n: number): string => (sinMiles ? numeroEditable(n) : numeroConMiles(n))

  // Obligatorio: vacío no es un número. Con un mínimo mayor que 0 y sin `emptyValue`, vacío se
  // completaba con el mínimo sin que se viera (B23).
  const vacioEnRojo = !onVaciar && (motivoVacio !== undefined || (emptyValue === undefined && typeof min === 'number' && min > 0))

  /**
   * Por qué lo escrito no sirve, o null si sirve. Lo decide el mismo lector que `toNumber`: lo que no
   * se entiende, lo que queda fuera del límite y, en un campo obligatorio, el vacío.
   */
  const motivo = (raw: string | null): string | null => {
    if (raw === null) return null
    if (raw.trim() === '') return vacioEnRojo ? (motivoVacio ?? 'Poné un número') : null
    const n = toNumber(raw)
    if (n === null) {
      const leido = integer ? leerNumero(raw) : sinMiles ? leerDecimalSinMiles(raw) : leerNumero(raw)
      if (leido !== null && leido < 0) return MENSAJE_NEGATIVO
      if (integer && leido !== null) return MENSAJE_ENTERO_CON_COMA
      return NUMERO_ILEGIBLE
    }
    if (typeof min === 'number' && n < min) return motivoMin ?? `El mínimo es ${mostrar(min)}`
    if (typeof max === 'number' && n > max) return motivoMax ?? `No puede pasar de ${mostrar(max)}`
    return null
  }

  // El último número que este campo le mandó al padre: si el `value` cambia a otra cosa, lo cambió
  // el padre (un botón «Total», «50%»), y el borrador deja de taparlo.
  const enviado = useRef<number | null>(value)
  const enviar = (n: number): void => {
    enviado.current = n
    onChange(n)
  }

  const valorDelPadre = sinMiles ? numeroEditable(value) : numeroConMiles(value)

  // El valor que tenía el padre antes de empezar a tipear (H4 de la segunda lente). Con
  // `commitOnChange`, mientras lo tipeado no se entiende, el padre vuelve a tener ESTE valor: nunca
  // el último pedazo legible («1.200» tipeado pasaba por «1», y Guardar guardaba 1).
  const antesDeTipear = useRef<number | null>(value)
  const restaurar = (): void => {
    const antes = antesDeTipear.current
    if (enviado.current === antes) return
    if (antes !== null) {
      enviar(antes)
      return
    }
    // Estaba vacío (N9 de la segunda pasada): vuelve a vacío, no se queda con el pedazo legible.
    enviado.current = null
    if (onVaciar) onVaciar()
    else if (emptyValue !== undefined) enviar(emptyValue)
  }

  const handleChange = (e: ChangeEvent<HTMLInputElement>): void => {
    const crudo = e.target.value
    let next: string
    if (sinMiles) {
      const tecleado = teclearNumero(display, crudo, e.target.selectionStart ?? undefined)
      if (tecleado !== crudo) cursor.current = e.target.selectionStart
      // Lo insertado de una vez (pegado, el chip del portapapeles, el dictado: T3 de la tercera
      // pasada) entra tal cual para que el lector lo marque si no lo entiende; filtrarlo haría de
      // «1.234,5» un 1,2345 callado. Lo tipeado de a una tecla se filtra.
      next = esPegado(e, display) || crudo.length - display.length > 1 ? tecleado.trim() : sanitizeSinMiles(tecleado)
    } else {
      const direccion = (e.nativeEvent as InputEvent).inputType === 'deleteContentForward' ? 'adelante' : 'atras'
      const r = formatearTecleo(display, crudo, e.target.selectionStart ?? crudo.length, { direccion })
      cursor.current = r.cursor
      next = r.texto
    }
    if (draft === null) antesDeTipear.current = value
    // Un pegado (lo dice el evento, N8) viene con formato de plata: no tiene nada que avisar.
    setPegado(esPegado(e, display))
    setDraft(next)
    setAviso(null)
    setAvisoGuardado(null)
    if (commitOnChange) {
      // En vivo mandamos el número crudo (como hacía el parseInt anterior);
      // el clamp/normalización quedan para el blur. El vacío NO empuja 0:
      // se mantiene el último valor y el campo se ve vacío. Lo que no sirve no se manda: el padre
      // vuelve al valor de antes de tipear. Lo mismo fuera del límite, o vacío en un campo
      // obligatorio: nunca el número recortado ni el mínimo (B23).
      const n = motivo(next) === null ? toNumber(next) : null
      if (n !== null) enviar(n)
      else if (next.trim() !== '' || vacioEnRojo) restaurar()
    }
  }

  const commit = (): void => {
    if (draft === null) return
    // Lo que no sirve no se confirma. Con un registro alrededor (el formulario no guarda mientras haya
    // un campo en rojo), queda en rojo para corregirlo. Sin registro, el campo vuelve al valor de antes
    // de tipear (que es lo que se va a guardar) y lo dice a la vista. Lo mismo fuera del límite: no
    // se recorta ni se completa (B23).
    const porQue = motivo(draft)
    if (porQue !== null) {
      if (commitOnChange) restaurar()
      if (conRegistro) return
      const anterior = sinMiles ? numeroEditable(antesDeTipear.current) : numeroConMiles(antesDeTipear.current)
      const volvio = `el campo volvió a ${anterior === '' ? 'quedar vacío' : `«${anterior}»`}`
      setDraft(null)
      setAviso(toNumber(draft) === null && draft.trim() !== '' ? `No se entendió «${draft}»: ${volvio}` : `${porQue}: ${volvio}`)
      return
    }
    const parsed = toNumber(draft)
    setAvisoGuardado(avisoDeDecimales(draft))
    setDraft(null)
    if (parsed === null && onVaciar) {
      onVaciar()
      return
    }
    enviar(parsed ?? emptyValue ?? 0)
  }

  // Un cambio del padre desde afuera limpia el borrador (y el aviso): si no, el campo seguiría
  // mostrando lo tipeado en vez del valor nuevo.
  useEffect(() => {
    if (value === enviado.current) return
    enviado.current = value
    setDraft(d => (d !== null && toNumber(d) === value ? d : null))
    setAviso(null)
    setAvisoGuardado(null)
    // eslint-disable-next-line react-hooks/exhaustive-deps -- sólo cuando cambia el valor del padre
  }, [value])

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
  const display = draft !== null ? draft : valorDelPadre
  /** El aviso de los decimales de más de lo tipeado, si corresponde. */
  function avisoDeDecimales(raw: string): string | null {
    if (integer || sinMiles || pegado || motivo(raw) !== null) return null
    return avisoPlataDecimalesDeMas(raw, decimales)
  }
  const avisoDecimales = draft !== null ? avisoDeDecimales(draft) : avisoGuardado
  const error = motivo(draft)
  const invalido = error !== null
  // En el registro del formulario: no se guarda mientras esté en rojo.
  const conRegistro = useAnotarIlegible(error, inputRef)
  const mensaje = error ?? aviso

  const avisado = useRef(true)
  useEffect(() => {
    if (avisado.current === !invalido) return
    avisado.current = !invalido
    onValidez?.(!invalido)
  }, [invalido, onValidez])

  const describedBy = [rest['aria-describedby'], mensaje ? idMensaje : null].filter(Boolean).join(' ') || undefined

  return (
    <>
      {avisoDecimales && !invalido && (
        <span role="status" className={CLASES_AVISO_DECIMALES}>{avisoDecimales}</span>
      )}
      <input
        {...rest}
        ref={inputRef}
        // Un campo opcional dice a la vista lo que vale vacío (B23).
        placeholder={rest.placeholder ?? (emptyValue !== undefined && !onVaciar ? mostrar(emptyValue) : undefined)}
        type="text"
        inputMode={integer ? 'numeric' : 'decimal'}
        aria-invalid={invalido ? true : rest['aria-invalid']}
        aria-describedby={describedBy}
        className={invalido ? `${rest.className ?? ''} ${CLASES_ILEGIBLE}` : rest.className}
        value={display}
        onChange={handleChange}
        onFocus={handleFocus}
        onBlur={handleBlur}
        onKeyDown={handleKeyDown}
      />
      {mensaje && (
        <span
          id={idMensaje}
          role="alert"
          className="block w-full basis-full mt-1 text-xs font-medium text-red-600 dark:text-red-400"
        >
          {mensaje}
        </span>
      )}
    </>
  )
}

export default NumberInput

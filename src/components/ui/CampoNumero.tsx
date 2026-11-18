/**
 * CampoNumero - Un `<input>` de texto para un número que el padre guarda como texto (D17, #1560).
 *
 * Es lo mismo que `NumberInput` para los formularios que leen el texto al guardar (con
 * `parsePrecio`, `leerPlataTipeada`, `leerEntero` o `parseMonto`) y tienen su propio mensaje de
 * error: el punto y la coma tipeados son decimales (la tecla del punto se ve como coma), el punto
 * de miles lo pone el campo mientras se tipea («150000» se ve «150.000»), lo pegado se lee como se
 * muestra la plata («1.250,50» es 1250,5), y el cursor queda después del mismo dígito.
 *
 * Con `sinMiles` (porcentajes, coordenadas, litros) no hay miles: la tecla del punto es coma y
 * nada más. Lo que no se entiende queda en rojo con el motivo escrito debajo: `motivo` lo pone el
 * padre si tiene una regla propia; si no, se usa el del lector (`esTextoIlegible`). El padre no
 * guarda lo que no se entiende: lee el texto y lo rechaza.
 *
 * La precarga va con `numeroConMiles` (o `numeroEditable` con `sinMiles`).
 */
import { useId, type ChangeEvent, type InputHTMLAttributes, type ReactElement } from 'react'
import { useTecleoNumero } from '../../hooks/useTecleoNumero'
import { NUMERO_ILEGIBLE, esTextoIlegible, motivoEnteroTipeado, teclearNumero } from '../../utils/normalizarNumero'

type PropsHeredadas = Omit<InputHTMLAttributes<HTMLInputElement>, 'value' | 'onChange' | 'type' | 'inputMode'>

export interface CampoNumeroProps extends PropsHeredadas {
  value: string
  onChange: (texto: string) => void
  /** Sin miles: porcentajes, coordenadas, litros. */
  sinMiles?: boolean
  /** Cantidades: teclado sin coma (`inputMode="numeric"`). */
  entero?: boolean
  /** Acepta un menos tipeado al principio. */
  negativo?: boolean
  /**
   * El motivo por el que lo escrito no sirve, si el padre tiene una regla propia (un rango, un
   * entero). `undefined` usa la del lector: «no se entiende» si `leerNumero` no lo lee, y con
   * `entero`, además, «las cantidades van sin coma».
   */
  motivo?: string | null
}

/** El rojo le gana a las clases del campo: el borde oscuro, el anillo del foco y los de color. */
export const CLASES_CAMPO_ILEGIBLE = '!border-red-500 dark:!border-red-500 !ring-1 !ring-red-500 focus:!ring-2 focus:!ring-red-500'

export function CampoNumero({
  value,
  onChange,
  sinMiles = false,
  entero = false,
  negativo = false,
  motivo,
  className,
  ...resto
}: CampoNumeroProps): ReactElement {
  const tecleo = useTecleoNumero({ negativo })
  const idMensaje = useId()
  const error = motivo !== undefined
    ? motivo
    : entero ? motivoEnteroTipeado(value) : esTextoIlegible(value) ? NUMERO_ILEGIBLE : null

  const alCambiar = (e: ChangeEvent<HTMLInputElement>): void => {
    if (sinMiles) onChange(teclearNumero(value, e.target.value, e.target.selectionStart ?? undefined))
    else onChange(tecleo(value, e))
  }

  const describedBy = [resto['aria-describedby'], error ? idMensaje : null].filter(Boolean).join(' ') || undefined

  return (
    <>
      <input
        autoComplete="off"
        {...resto}
        type="text"
        inputMode={entero ? 'numeric' : 'decimal'}
        value={value}
        onChange={alCambiar}
        aria-invalid={error ? true : resto['aria-invalid']}
        aria-describedby={describedBy}
        className={error ? `${className ?? ''} ${CLASES_CAMPO_ILEGIBLE}` : className}
      />
      {error && (
        <span id={idMensaje} role="alert" className="block w-full basis-full mt-1 text-xs font-medium text-red-600 dark:text-red-400">
          {error}
        </span>
      )}
    </>
  )
}

export default CampoNumero

/**
 * CampoNumero - Un `<input>` de texto para un número que el padre guarda como texto (D17, #1560).
 *
 * Es lo mismo que `NumberInput` para los formularios que leen el texto al guardar: el punto y la
 * coma tipeados son decimales (la tecla del punto se ve como coma), el punto de miles lo pone el
 * campo mientras se tipea («150000» se ve «150.000»), lo pegado se lee como se muestra la plata
 * («1.250,50» es 1250,5), y el cursor queda después del mismo dígito.
 *
 * Qué lector decide el rojo (y el formulario tiene que leer con ESE mismo, nunca con otro):
 * - por defecto, plata: `leerNumero`, sin negativos salvo `negativo` (`motivoPlataTipeada`). Con
 *   más de `decimales` decimales (2) TIPEADOS no hay rojo: se guarda al centavo y un aviso amarillo
 *   arriba del campo dice qué se guarda (decisión del dueño, 17/11: «Que guarde 1,50 pero salga un
 *   aviso en amarillo no grande sobre el campo»);
 * - `entero`: `leerEntero` (`motivoEnteroTipeado`);
 * - `sinMiles` (porcentajes, coordenadas, litros): `leerDecimalSinMiles` (`motivoSinMilesTipeado`).
 *   No hay miles; la tecla del punto es la coma, y sólo entran dígitos, un separador y el menos.
 * `motivo` lo pone el padre si tiene una regla propia, y reemplaza al del lector.
 *
 * Lo que no se entiende queda en rojo con el motivo escrito debajo, y se anota en el registro del
 * formulario (`useRegistroIlegibles`): el formulario no guarda mientras haya uno.
 *
 * La precarga va con `numeroConMiles` (o `numeroEditable` con `sinMiles`).
 */
import { useId, useLayoutEffect, useRef, useState, type ChangeEvent, type InputHTMLAttributes, type ReactElement, type ReactNode, type Ref } from 'react'
import { CLASES_AVISO_DECIMALES, avisoPlataDecimalesDeMas, avisoSinMilesDecimalesDeMas } from '../../utils/avisoDecimales'
import { esPegado, useTecleoNumero } from '../../hooks/useTecleoNumero'
import { useAnotarIlegible } from '../../hooks/useRegistroIlegibles'
import {
  motivoEnteroTipeado,
  motivoPlataTipeada,
  motivoSinMilesTipeado,
  teclearNumero,
} from '../../utils/normalizarNumero'

type PropsHeredadas = Omit<InputHTMLAttributes<HTMLInputElement>, 'value' | 'onChange' | 'type' | 'inputMode'>

export interface CampoNumeroProps extends PropsHeredadas {
  value: string
  onChange: (texto: string) => void
  /** Sin miles: porcentajes, coordenadas, litros. Lo lee `leerDecimalSinMiles`. */
  sinMiles?: boolean
  /** Cantidades: teclado sin coma (`inputMode="numeric"`). Lo lee `leerEntero`. */
  entero?: boolean
  /** Acepta un menos tipeado al principio (y uno pegado no queda en rojo). */
  negativo?: boolean
  /**
   * Cuántos decimales guarda: por defecto 2 en la plata; con `sinMiles`, sin tope salvo que se
   * diga. Lo tipeado con más sale con el aviso amarillo de lo que se guarda.
   */
  decimales?: number
  /**
   * El motivo por el que lo escrito no sirve, si el padre tiene una regla propia (un rango).
   * `undefined` usa la del lector del campo.
   */
  motivo?: string | null
  /** El input (para enfocarlo desde el formulario, como los precios del grupo de precio). */
  ref?: Ref<HTMLInputElement>
  /**
   * Lo que va pegado a la izquierda del input («$»), centrado en el input y no en el bloque: puesto
   * por el formulario, con el aviso arriba o el motivo abajo quedaba corrido (N12). El input deja
   * lugar con su `pl-*`.
   */
  prefijo?: ReactNode
  /** Las clases del prefijo, si no van las de siempre. */
  clasePrefijo?: string
}

/** El rojo le gana a las clases del campo: el borde oscuro, el anillo del foco y los de color. */
export const CLASES_CAMPO_ILEGIBLE = '!border-red-500 dark:!border-red-500 !ring-1 !ring-red-500 focus:!ring-2 focus:!ring-red-500'

/** Sin miles: dígitos, un solo separador (el decimal, como coma) y el menos al principio. */
function filtrarSinMiles(texto: string, negativo: boolean): string {
  const signo = negativo && texto.trimStart().startsWith('-') ? '-' : ''
  let s = texto.replace(/[^\d.,]/g, '')
  const sep = s.search(/[.,]/)
  if (sep !== -1) s = `${s.slice(0, sep)},${s.slice(sep + 1).replace(/[.,]/g, '')}`
  return signo + s
}

export function CampoNumero({
  value,
  onChange,
  sinMiles = false,
  entero = false,
  negativo = false,
  decimales,
  motivo,
  className,
  ref,
  prefijo,
  clasePrefijo = 'left-3 text-gray-400',
  ...resto
}: CampoNumeroProps): ReactElement {
  const tecleo = useTecleoNumero({ negativo })
  const idMensaje = useId()
  const input = useRef<HTMLInputElement | null>(null)
  const cursor = useRef<number | null>(null)
  useLayoutEffect(() => {
    if (cursor.current !== null && input.current && document.activeElement === input.current) {
      input.current.setSelectionRange(cursor.current, cursor.current)
    }
    cursor.current = null
  })

  const error = motivo !== undefined
    ? motivo
    : entero
      ? motivoEnteroTipeado(value, { negativo })
      : sinMiles
        ? motivoSinMilesTipeado(value, { negativo })
        : motivoPlataTipeada(value, { negativo })
  useAnotarIlegible(error, input)

  // El aviso de los decimales de más sale con lo TIPEADO (no con lo precargado ni lo pegado), y
  // queda a la vista hasta que el valor cambie: `tecleo` es el último texto que entró por el teclado.
  const [tecleado, setTecleado] = useState<string | null>(null)
  const avisoDecimales = error || entero || tecleado !== value
    ? null
    : sinMiles
      ? decimales !== undefined ? avisoSinMilesDecimalesDeMas(value, decimales) : null
      : avisoPlataDecimalesDeMas(value, decimales ?? 2)
  const anotar = (pegado: boolean, nuevo: string): void => {
    setTecleado(pegado ? null : nuevo)
    onChange(nuevo)
  }

  const alCambiar = (e: ChangeEvent<HTMLInputElement>): void => {
    const pegado = esPegado(e, value)
    if (!sinMiles) {
      anotar(pegado, tecleo(value, e))
      return
    }
    // Sin miles: la tecla del punto es la coma, y el cursor se repone después del mismo carácter.
    const crudo = e.target.value
    const posicion = e.target.selectionStart ?? crudo.length
    const tecleado = teclearNumero(value, crudo, posicion)
    // Lo pegado (lo dice el evento: `esPegado`) entra tal cual, para que el lector lo marque si no lo entiende:
    // filtrarlo haría de «1.234,5» un 1,2345 callado.
    if (pegado) {
      anotar(true, tecleado)
      return
    }
    const filtrado = filtrarSinMiles(tecleado, negativo)
    const antes = filtrarSinMiles(tecleado.slice(0, posicion), negativo).length
    cursor.current = Math.min(antes, filtrado.length)
    anotar(false, filtrado)
  }

  const describedBy = [resto['aria-describedby'], error ? idMensaje : null].filter(Boolean).join(' ') || undefined

  const campo = (
      <input
        autoComplete="off"
        {...resto}
        ref={el => {
          input.current = el
          if (typeof ref === 'function') ref(el)
          else if (ref) ref.current = el
        }}
        type="text"
        inputMode={entero ? 'numeric' : 'decimal'}
        value={value}
        onChange={alCambiar}
        aria-invalid={error ? true : resto['aria-invalid']}
        aria-describedby={describedBy}
        className={error ? `${className ?? ''} ${CLASES_CAMPO_ILEGIBLE}` : className}
      />
  )

  return (
    <>
      {avisoDecimales && (
        <span role="status" className={CLASES_AVISO_DECIMALES}>{avisoDecimales}</span>
      )}
      {prefijo !== undefined ? (
        <span className="relative block">
          <span className={`absolute top-1/2 -translate-y-1/2 ${clasePrefijo}`} aria-hidden="true">{prefijo}</span>
          {campo}
        </span>
      ) : campo}
      {error && (
        <span id={idMensaje} role="alert" className="block w-full basis-full mt-1 text-xs font-medium text-red-600 dark:text-red-400">
          {error}
        </span>
      )}
    </>
  )
}

export default CampoNumero

/**
 * InputMonto - Campo de importe de gastos y personal. El valor es el texto, y lo lee `parseMonto`
 * (sin signo, al centavo).
 *
 * Sigue la regla del dueño (D17, B20 de #1603), como `NumberInput` y `CampoNumero`: el punto y la
 * coma tipeados son decimales (la tecla del punto se ve como coma), y el punto de miles lo pone el
 * campo mientras se tipea («280000» → «280.000»). Lo pegado se lee como se muestra la plata
 * («1.250,50» es 1250,5). Antes un punto tipeado con tres dígitos detrás era de miles («1.500» era
 * mil quinientos); ahora es la coma («1,500», que se guarda $ 1,50 con el aviso amarillo).
 *
 * Lo que `parseMonto` no entiende queda en rojo (`aria-invalid`) y se anota en el registro del
 * formulario (`useRegistroIlegibles`); el motivo lo dice el campo si hay un registro alrededor, y si
 * no, el formulario al guardar (`MENSAJE_MONTO_ILEGIBLE`), que no lo guarda.
 *
 * `prefijo` («$») lo pone el campo pegado al input (N12 de la segunda pasada de #1644): puesto por el
 * formulario, centrado en un `div.relative` que también tiene el aviso arriba y el motivo abajo,
 * quedaba montado sobre el borde. `avisoCorto` deja sólo «Se guarda $ 1,50.» para una columna angosta.
 */
import { useId, useRef, useState, type InputHTMLAttributes, type ReactNode } from 'react'
import { CLASES_AVISO_DECIMALES, avisoPlataDecimalesDeMas } from '../../utils/avisoDecimales'
import { esPegado, useTecleoNumero } from '../../hooks/useTecleoNumero'
import { MENSAJE_MONTO_ILEGIBLE, parseMonto } from '../../utils/personal'
import { useAnotarIlegible } from '../../hooks/useRegistroIlegibles'
import { CLASES_CAMPO_ILEGIBLE } from './CampoNumero'

type PropsHeredadas = Omit<InputHTMLAttributes<HTMLInputElement>, 'value' | 'onChange' | 'type' | 'inputMode'>

export interface InputMontoProps extends PropsHeredadas {
  value: string
  onChange: (valor: string) => void
  /** Lo que va pegado a la izquierda del input («$»); el input deja lugar con su `pl-*`. */
  prefijo?: ReactNode
  /** Sólo la primera mitad del aviso amarillo, para una columna angosta. */
  avisoCorto?: boolean
}

export function InputMonto({ value, onChange, className, prefijo, avisoCorto = false, ...resto }: InputMontoProps) {
  // El menos tipeado queda a la vista para que parseMonto lo rechace: el signo lo dan los botones.
  const tecleo = useTecleoNumero({ negativo: true })
  const input = useRef<HTMLInputElement>(null)
  const ilegible = value.trim() !== '' && parseMonto(value) === null
  // En el registro del formulario: no se guarda mientras esté en rojo.
  const conRegistro = useAnotarIlegible(ilegible ? MENSAJE_MONTO_ILEGIBLE : null, input)
  const idMensaje = useId()
  // Con un registro alrededor el formulario no deja guardar, así que no llega a decir el motivo: lo
  // dice el campo. Sin registro, lo dice el formulario al guardar (como siempre).
  const motivoVisible = ilegible && conRegistro
  // El aviso amarillo de los decimales de más (decisión del dueño, 17/11): sólo con lo TIPEADO, y a
  // la vista hasta que el valor cambie. `tecleado` es el último texto que entró por el teclado.
  const [tecleado, setTecleado] = useState<string | null>(null)
  const avisoEntero = !ilegible && tecleado === value ? avisoPlataDecimalesDeMas(value) : null
  const aviso = avisoEntero && avisoCorto ? avisoEntero.replace(/\. Para .*$/, '.') : avisoEntero
  const campo = (
    <input
      autoComplete="off"
      {...resto}
      ref={input}
      type="text"
      inputMode="decimal"
      value={value}
      aria-invalid={ilegible ? true : resto['aria-invalid']}
      aria-describedby={[resto['aria-describedby'], motivoVisible ? idMensaje : null].filter(Boolean).join(' ') || undefined}
      className={ilegible ? `${className ?? ''} ${CLASES_CAMPO_ILEGIBLE}` : className}
      onChange={e => {
        const nuevo = tecleo(value, e)
        setTecleado(esPegado(e, value) ? null : nuevo)
        onChange(nuevo)
      }}
    />
  )
  return (
    <>
    {aviso && <span role="status" className={CLASES_AVISO_DECIMALES}>{aviso}</span>}
    {prefijo !== undefined ? (
      <span className="relative block">
        <span className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" aria-hidden="true">{prefijo}</span>
        {campo}
      </span>
    ) : campo}
    {motivoVisible && (
      <span id={idMensaje} role="alert" className="block w-full basis-full mt-1 text-xs font-medium text-red-600 dark:text-red-400">
        {MENSAJE_MONTO_ILEGIBLE}
      </span>
    )}
    </>
  )
}

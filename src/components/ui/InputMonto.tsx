/**
 * InputMonto - Campo de importe de gastos y personal. El valor es el texto, y lo lee `parseMonto`
 * (sin signo, hasta dos decimales).
 *
 * Sigue la regla del dueño (D17, B20 de #1603), como `NumberInput` y `CampoNumero`: el punto y la
 * coma tipeados son decimales (la tecla del punto se ve como coma), y el punto de miles lo pone el
 * campo mientras se tipea («280000» → «280.000»). Lo pegado se lee como se muestra la plata
 * («1.250,50» es 1250,5). Antes un punto tipeado con tres dígitos detrás era de miles («1.500» era
 * mil quinientos); ahora es la coma («1,500», que `parseMonto` rechaza por tener tres decimales).
 *
 * Lo que `parseMonto` no entiende queda en rojo (`aria-invalid`) y se anota en el registro del
 * formulario (`useRegistroIlegibles`); el motivo lo dice el formulario (`MENSAJE_MONTO_ILEGIBLE`),
 * que no lo guarda.
 */
import { useId, useState, type InputHTMLAttributes } from 'react'
import { CLASES_AVISO_DECIMALES, avisoPlataDecimalesDeMas } from '../../utils/avisoDecimales'
import { useTecleoNumero } from '../../hooks/useTecleoNumero'
import { MENSAJE_MONTO_ILEGIBLE, parseMonto } from '../../utils/personal'
import { useAnotarIlegible } from '../../hooks/useRegistroIlegibles'
import { CLASES_CAMPO_ILEGIBLE } from './CampoNumero'

type PropsHeredadas = Omit<InputHTMLAttributes<HTMLInputElement>, 'value' | 'onChange' | 'type' | 'inputMode'>

export interface InputMontoProps extends PropsHeredadas {
  value: string
  onChange: (valor: string) => void
}

export function InputMonto({ value, onChange, className, ...resto }: InputMontoProps) {
  // El menos tipeado queda a la vista para que parseMonto lo rechace: el signo lo dan los botones.
  const tecleo = useTecleoNumero({ negativo: true })
  const ilegible = value.trim() !== '' && parseMonto(value) === null
  // En el registro del formulario: no se guarda mientras esté en rojo.
  const conRegistro = useAnotarIlegible(ilegible ? MENSAJE_MONTO_ILEGIBLE : null)
  const idMensaje = useId()
  // Con un registro alrededor el formulario no deja guardar, así que no llega a decir el motivo: lo
  // dice el campo. Sin registro, lo dice el formulario al guardar (como siempre).
  const motivoVisible = ilegible && conRegistro
  // El aviso amarillo de los decimales de más (decisión del dueño, 17/11): sólo con lo TIPEADO, y a
  // la vista hasta que el valor cambie. `tecleado` es el último texto que entró por el teclado.
  const [tecleado, setTecleado] = useState<string | null>(null)
  const aviso = !ilegible && tecleado === value ? avisoPlataDecimalesDeMas(value) : null
  return (
    <>
    {aviso && <span role="status" className={CLASES_AVISO_DECIMALES}>{aviso}</span>}
    <input
      autoComplete="off"
      {...resto}
      type="text"
      inputMode="decimal"
      value={value}
      aria-invalid={ilegible ? true : resto['aria-invalid']}
      aria-describedby={[resto['aria-describedby'], motivoVisible ? idMensaje : null].filter(Boolean).join(' ') || undefined}
      className={ilegible ? `${className ?? ''} ${CLASES_CAMPO_ILEGIBLE}` : className}
      onChange={e => {
        const nuevo = tecleo(value, e)
        setTecleado(e.target.value.length - value.length > 1 ? null : nuevo)
        onChange(nuevo)
      }}
    />
    {motivoVisible && (
      <span id={idMensaje} role="alert" className="block w-full basis-full mt-1 text-xs font-medium text-red-600 dark:text-red-400">
        {MENSAJE_MONTO_ILEGIBLE}
      </span>
    )}
    </>
  )
}

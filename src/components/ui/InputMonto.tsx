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
 * Lo que `parseMonto` no entiende queda en rojo (`aria-invalid`); el motivo lo dice el formulario
 * al guardar (`MENSAJE_MONTO_ILEGIBLE`), que no lo guarda.
 */
import type { InputHTMLAttributes } from 'react'
import { useTecleoNumero } from '../../hooks/useTecleoNumero'
import { parseMonto } from '../../utils/personal'
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
  return (
    <input
      autoComplete="off"
      {...resto}
      type="text"
      inputMode="decimal"
      value={value}
      aria-invalid={ilegible ? true : resto['aria-invalid']}
      className={ilegible ? `${className ?? ''} ${CLASES_CAMPO_ILEGIBLE}` : className}
      onChange={e => onChange(tecleo(value, e))}
    />
  )
}

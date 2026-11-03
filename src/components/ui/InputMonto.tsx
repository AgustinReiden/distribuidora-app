/**
 * InputMonto - Campo de importe que pone solo los puntos de miles mientras se tipea
 * («280000» → «280.000») y, al salir, escribe con coma el decimal tipeado con punto
 * («12.5» → «12,5»). El valor sigue siendo el texto: lo lee `parseMonto`. Las reglas viven en
 * `formatearMontoTipeado` y `cerrarMontoTipeado`.
 */
import { useLayoutEffect, useRef, type InputHTMLAttributes } from 'react'
import { cerrarMontoTipeado, formatearMontoTipeado } from '../../utils/personal'

type PropsHeredadas = Omit<InputHTMLAttributes<HTMLInputElement>, 'value' | 'onChange' | 'type' | 'inputMode'>

export interface InputMontoProps extends PropsHeredadas {
  value: string
  onChange: (valor: string) => void
}

export function InputMonto({ value, onChange, onBlur, ...resto }: InputMontoProps) {
  const ref = useRef<HTMLInputElement>(null)
  // Al reformatear, React deja el cursor al final: se repone después del mismo dígito.
  const cursor = useRef<number | null>(null)
  useLayoutEffect(() => {
    const input = ref.current
    if (cursor.current !== null && input && document.activeElement === input) {
      input.setSelectionRange(cursor.current, cursor.current)
    }
    cursor.current = null
  })

  return (
    <input
      autoComplete="off"
      {...resto}
      ref={ref}
      type="text"
      inputMode="decimal"
      value={value}
      onChange={e => {
        const formateado = formatearMontoTipeado(e.target.value, value, e.target.selectionStart ?? e.target.value.length)
        cursor.current = formateado.cursor
        onChange(formateado.texto)
      }}
      onBlur={e => {
        const cerrado = cerrarMontoTipeado(value)
        if (cerrado !== value) onChange(cerrado)
        onBlur?.(e)
      }}
    />
  )
}

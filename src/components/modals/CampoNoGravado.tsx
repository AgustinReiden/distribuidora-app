/**
 * El «No gravado» de la cabecera de una FC (#1590; H7 de la revisión de C3, #1603).
 *
 * Puede ser negativo: un descuento sobre renglones exentos o no gravados lo baja, hasta lo que
 * suman esos descuentos de la factura (`pisoNoGravado`; la base pone el mismo piso). Es un
 * `CampoNumero` de plata con `negativo` (regla de números tipeados de CLAUDE.md): lo que no se
 * entiende o queda debajo del piso va en rojo con su motivo, se anota en el registro del
 * formulario y no se guarda. Lo que sí sirve sube con `onChange` como número.
 */
import { useState } from 'react'
import { CampoNumero } from '../ui/CampoNumero'
import { leerNumero, numeroConMiles } from '../../utils/normalizarNumero'
import { formatPrecio } from '../../utils/formatters'

interface CampoNoGravadoProps {
  valor: number
  /** Hasta dónde puede bajar (0, o lo que suman los descuentos no gravados de la factura). */
  piso: number
  onChange: (n: number) => void
  className?: string
}

export default function CampoNoGravado({ valor, piso, onChange, className }: CampoNoGravadoProps) {
  const [texto, setTexto] = useState(() => numeroConMiles(valor))
  // El valor que este campo subió por última vez: si el padre trae otro (los cargos cambiaron, o
  // se volvió a «usar los cargos»), el texto lo sigue.
  const [subido, setSubido] = useState(valor)
  if (valor !== subido) {
    setSubido(valor)
    setTexto(numeroConMiles(valor))
  }

  const n = leerNumero(texto)
  const debajo = texto.trim() !== '' && n !== null && n < piso
  const motivo = debajo
    ? `No puede bajar de ${formatPrecio(piso)}: sólo un descuento no gravado o exento de la factura lo deja negativo, y hasta lo que suman`
    : undefined

  return (
    <CampoNumero
      negativo
      value={texto}
      onChange={(t) => {
        setTexto(t)
        const leido = t.trim() === '' ? 0 : leerNumero(t)
        if (leido !== null && leido >= piso) {
          setSubido(leido)
          onChange(leido)
        }
      }}
      motivo={motivo}
      aria-label="No gravado"
      className={className}
    />
  )
}

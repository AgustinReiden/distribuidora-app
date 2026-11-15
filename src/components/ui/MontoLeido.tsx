/**
 * MontoLeido - Debajo de un campo de plata, el monto como la app lo leyó (#1560).
 *
 * El cobrador escribe «150.000» y ve «Se registra: $ 150.000,00» antes de confirmar. Si el
 * campo leyó otra cosa, se nota ahí y no en la boleta. No muestra nada mientras el monto es 0.
 */
import type { ReactElement } from 'react'
import { formatPrecio } from '../../utils/formatters'

export interface MontoLeidoProps {
  /** El monto ya leído (lo que se va a mandar). */
  monto: number
  className?: string
}

export function MontoLeido({ monto, className = '' }: MontoLeidoProps): ReactElement | null {
  if (!(monto > 0)) return null
  return (
    <p className={`mt-1 text-xs text-gray-500 dark:text-gray-400 ${className}`} aria-live="polite">
      Se registra:{' '}
      <span className="font-semibold text-gray-800 dark:text-gray-100">{formatPrecio(monto)}</span>
    </p>
  )
}

export default MontoLeido

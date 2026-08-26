/**
 * Compra mínima en $ por pedido.
 *
 * Espejo EXACTO de `pedido_incumple_minimo` (mig 205). La regla vive en la base
 * para que valga en todos los caminos de alta, pero tiene que estar también acá:
 * si sólo viviera en SQL, un pedido cargado sin señal se aceptaría en el
 * teléfono, el preventista se iría del comercio, y el rechazo llegaría horas
 * después al sincronizar — quedando como una operación fallida en IndexedDB que
 * nadie mira. Es el mismo criterio que ya se usa para el mínimo por producto
 * (mig 147): validar en la base Y avisar antes de confirmar.
 *
 * Si cambiás esta regla, cambiá también `pedido_incumple_minimo`.
 */
import { formatCurrency } from './formatters'

/** Un pedido que da exactamente el mínimo pasa. */
export function cumpleMontoMinimo(total: number, minimo: number): boolean {
  if (!Number.isFinite(minimo) || minimo <= 0) return true // 0 = sin política
  return (Number.isFinite(total) ? total : 0) >= minimo
}

/**
 * Motivo del rechazo, o null si el pedido está bien.
 *
 * Devuelve el texto ya armado (con los dos montos) porque sale por caminos
 * donde nadie va a ir a buscar cuál era el mínimo.
 */
export function motivoMontoMinimo(total: number, minimo: number): string | null {
  if (cumpleMontoMinimo(total, minimo)) return null
  const faltante = minimo - (Number.isFinite(total) ? total : 0)
  return (
    `El pedido no alcanza la compra mínima de ${formatCurrency(minimo)}. ` +
    `Faltan ${formatCurrency(faltante)}.`
  )
}

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

/**
 * Compra mínima con cargo de envío (mig 389, #1220).
 *
 * Tres modos, que se eligen en /configuracion:
 *   - 'bloquear': bajo `montoMinimo` el pedido se rechaza (lo de la mig 205).
 *   - 'cargo':    bajo `montoMinimo` el pedido entra y paga `cargoEnvio`.
 *   - 'escalas':  bajo `montoMinimo` se rechaza; desde ahí y hasta
 *                 `montoEnvioGratis` entra y paga `cargoEnvio`; desde
 *                 `montoEnvioGratis`, ni se rechaza ni se cobra.
 *
 * Espejo de `pedido_incumple_minimo` y `pedido_cargo_envio`. Si cambiás una
 * regla, cambiá la otra. El `total` que reciben es la suma de los ítems, SIN el
 * cargo: el servidor decide el cargo y lo suma al guardar.
 */
export type ModoMinimoPedido = 'bloquear' | 'cargo' | 'escalas'

export interface ReglaMinimoPedido {
  modo: ModoMinimoPedido
  montoMinimo: number
  montoEnvioGratis: number
  cargoEnvio: number
}

export const REGLA_MINIMO_POR_DEFECTO: ReglaMinimoPedido = {
  modo: 'bloquear',
  montoMinimo: 0,
  montoEnvioGratis: 0,
  cargoEnvio: 0,
}

/** La regla a partir de los campos de la política comercial de la sucursal. */
export function reglaMinimoDe(politicas: {
  montoMinimoPedido: number
  modoMinimoPedido: ModoMinimoPedido
  montoEnvioGratis: number
  cargoEnvioPedido: number
}): ReglaMinimoPedido {
  return {
    modo: politicas.modoMinimoPedido,
    montoMinimo: politicas.montoMinimoPedido,
    montoEnvioGratis: politicas.montoEnvioGratis,
    cargoEnvio: politicas.cargoEnvioPedido,
  }
}

/** Motivo del rechazo según el modo, o null si el pedido puede cargarse. */
export function motivoRechazoMinimo(total: number, regla: ReglaMinimoPedido): string | null {
  if (regla.modo === 'cargo') return null
  return motivoMontoMinimo(total, regla.montoMinimo)
}

/** Cargo de envío que le toca a un pedido nuevo (0 si ninguno). */
export function cargoEnvioPedido(total: number, regla: ReglaMinimoPedido): number {
  const t = Number.isFinite(total) ? total : 0
  if (!(regla.cargoEnvio > 0)) return 0
  if (regla.modo === 'cargo') {
    return regla.montoMinimo > 0 && t < regla.montoMinimo ? regla.cargoEnvio : 0
  }
  if (regla.modo === 'escalas') {
    return t >= regla.montoMinimo && t < regla.montoEnvioGratis ? regla.cargoEnvio : 0
  }
  return 0
}

/** Cuánto falta para no pagar envío, o null si el pedido no lo paga. */
export function faltanteParaEnvioGratis(total: number, regla: ReglaMinimoPedido): number | null {
  if (cargoEnvioPedido(total, regla) <= 0) return null
  const umbral = regla.modo === 'cargo' ? regla.montoMinimo : regla.montoEnvioGratis
  return Math.max(umbral - (Number.isFinite(total) ? total : 0), 0)
}

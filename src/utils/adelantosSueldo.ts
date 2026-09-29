/**
 * Adelantos de sueldo (#832): pagos con forma_pago = 'adelanto_sueldo'.
 * Un empleado (cliente) se lleva mercadería y se registra como adelanto para
 * saber a quién hay que descontarle. El sueldo no se lleva en el sistema.
 */

export const FORMA_ADELANTO_SUELDO = 'adelanto_sueldo'

interface PagoConForma {
  forma_pago?: string | null
  monto?: number | string | null
}

export type FiltroFormaPago = 'todos' | typeof FORMA_ADELANTO_SUELDO

export function esAdelantoSueldo(pago: PagoConForma): boolean {
  return pago.forma_pago === FORMA_ADELANTO_SUELDO
}

export function filtrarPagosPorForma<T extends PagoConForma>(pagos: readonly T[], filtro: FiltroFormaPago): T[] {
  return filtro === 'todos' ? [...pagos] : pagos.filter(esAdelantoSueldo)
}

/** Suma de los adelantos de sueldo de una lista de pagos (los del cliente de la ficha). */
export function totalAdelantosSueldo(pagos: readonly PagoConForma[]): number {
  return pagos.filter(esAdelantoSueldo).reduce((sum, p) => sum + (Number(p.monto) || 0), 0)
}

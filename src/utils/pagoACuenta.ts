/**
 * Un pago a cuenta que pasa el doble de la deuda (#1559, 1559-b15).
 *
 * El FIFO de la ficha no tiene tope en el server: lo que sobra de la deuda queda a
 * favor del cliente (decisión del dueño D22, en #1559). Un cero de más ("100000"
 * por "10000") quedaba a favor sin que nadie lo viera, así que la pantalla pide
 * confirmar el monto cuando pasa el doble de lo que el cliente debe. Sin deuda
 * (o con saldo a favor), cualquier pago queda entero a favor: también se confirma.
 */
import { formatPrecio as formatCurrency } from './formatters'

/** Medio centavo: dos montos que redondean igual no cuentan como "más". */
const TOLERANCIA = 0.005

/** Lo que debe el cliente: un saldo negativo es saldo a favor, no deuda. */
function deudaDe(saldo: number): number {
  return Number.isFinite(saldo) ? Math.max(saldo, 0) : 0
}

/** Si el monto de un pago a cuenta pide confirmación: pasa el doble de la deuda. */
export function pagoACuentaPideConfirmacion(monto: number, saldoPendiente: number): boolean {
  if (!Number.isFinite(monto) || monto <= 0) return false
  return monto > 2 * deudaDe(saldoPendiente) + TOLERANCIA
}

/** El texto que acompaña la confirmación. */
export function avisoPagoACuentaGrande(monto: number, saldoPendiente: number): string {
  const deuda = deudaDe(saldoPendiente)
  if (deuda <= TOLERANCIA) {
    return `El cliente no debe nada: los ${formatCurrency(monto)} quedan enteros como saldo a favor. Revisá que el monto sea el correcto.`
  }
  return `El pago (${formatCurrency(monto)}) es más del doble de lo que debe el cliente (${formatCurrency(deuda)}): ` +
    `${formatCurrency(monto - deuda)} quedan como saldo a favor. Revisá que no sobre un cero.`
}

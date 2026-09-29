/**
 * Formas de pago soportadas por la app.
 *
 * Sincronizado con la RPC `obtener_resumen_rendiciones` (migraciones 003+ y 036):
 * las columnas `total_efectivo`, `total_transferencia`, `total_cheque`,
 * `total_cuenta_corriente`, `total_tarjeta`, `total_vale_blanco` y `total_otros`
 * se calculan según estas claves. `adelanto_sueldo` (mig 273, #832) queda FUERA de
 * todos los buckets: la RPC lo excluye y lo informa aparte en `total_adelanto_sueldo`. Cualquier forma de pago que se guarde en
 * `pagos.forma_pago` fuera de este set cae en el bucket `otros`.
 */

import type { FormaPago } from '../types'

export interface FormaPagoMeta {
  value: FormaPago
  /** Etiqueta visible en UI (es-AR) */
  label: string
  /** Color de acento (clase Tailwind) — coherente con VistaRendiciones */
  color: string
  /** Etiqueta corta para tarjetas con poco espacio */
  short: string
  /**
   * Si se puede ELEGIR como forma de pago en los selectores de cobranza/compra.
   * `cuenta_corriente` no es una forma de pago real (es una venta no cobrada): se
   * conserva en este set solo para etiquetas y reportes históricos, pero no debe
   * ofrecerse como opción. `otros` tampoco es seleccionable (bucket de fallback).
   */
  seleccionable: boolean
  /**
   * Forma NO dineraria (#832): cancela deuda del cliente pero no entra a rendiciones,
   * controles de efectivo ni a ningún bucket de dinero (tampoco a `otros`).
   */
  noDineraria?: boolean
}

export const FORMAS_PAGO: readonly FormaPagoMeta[] = [
  { value: 'efectivo', label: 'Efectivo', short: 'Ef.', color: 'emerald', seleccionable: true },
  { value: 'transferencia', label: 'Transferencia', short: 'Transf.', color: 'sky', seleccionable: true },
  { value: 'cheque', label: 'Cheque', short: 'Ch.', color: 'purple', seleccionable: true },
  { value: 'cuenta_corriente', label: 'Cuenta corriente', short: 'Cta. Cte.', color: 'amber', seleccionable: false },
  { value: 'tarjeta', label: 'Tarjeta', short: 'Tj.', color: 'indigo', seleccionable: true },
  { value: 'vale_blanco', label: 'Vale Blanco', short: 'V.B.', color: 'rose', seleccionable: true },
  // `seleccionable: false` a propósito: solo se ofrece desde la ficha del cliente
  // (ModalRegistrarPago con `permitirAdelantoSueldo`), nunca en los selectores generales.
  { value: 'adelanto_sueldo', label: 'Adelanto de sueldo', short: 'Adel. sueldo', color: 'orange', seleccionable: false, noDineraria: true },
  { value: 'otros', label: 'Otros', short: 'Otros', color: 'slate', seleccionable: false }
] as const

const FORMAS_PAGO_MAP: Record<FormaPago, FormaPagoMeta> = FORMAS_PAGO.reduce(
  (acc, meta) => {
    acc[meta.value] = meta
    return acc
  },
  {} as Record<FormaPago, FormaPagoMeta>
)

export function formaPagoMeta(value: FormaPago | string | null | undefined): FormaPagoMeta {
  if (value && value in FORMAS_PAGO_MAP) {
    return FORMAS_PAGO_MAP[value as FormaPago]
  }
  return FORMAS_PAGO_MAP.otros
}

export function formaPagoLabel(value: FormaPago | string | null | undefined): string {
  return formaPagoMeta(value).label
}

export const FORMA_PAGO_VALUES: readonly FormaPago[] = FORMAS_PAGO.map((m) => m.value)

/**
 * Formas de pago que SÍ se pueden elegir en los selectores (cobranza, pedido,
 * compra). Excluye `cuenta_corriente` (no es una forma de pago: es una venta no
 * cobrada) y `otros` (bucket de fallback). Usar esto para poblar `<select>`/
 * botones; usar `FORMAS_PAGO`/`formaPagoLabel` para mostrar valores históricos.
 */
export const FORMAS_PAGO_SELECCIONABLES: readonly FormaPagoMeta[] = FORMAS_PAGO.filter(
  (m) => m.seleccionable,
)

/** Formas de pago que cancelan deuda pero no son dinero (no van a rendiciones/efectivo). */
export const FORMAS_PAGO_NO_DINERARIAS: readonly FormaPago[] = FORMAS_PAGO
  .filter((m) => m.noDineraria)
  .map((m) => m.value)

/**
 * Formas de pago soportadas por la app.
 *
 * Sincronizado con la RPC `obtener_resumen_rendiciones` (migraciones 003+): las
 * columnas `total_efectivo`, `total_transferencia`, `total_cheque`,
 * `total_cuenta_corriente`, `total_tarjeta` y `total_otros` se calculan según
 * estas claves. Cualquier forma de pago que se guarde en `pagos.forma_pago`
 * fuera de este set cae en el bucket `otros`.
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
}

export const FORMAS_PAGO: readonly FormaPagoMeta[] = [
  { value: 'efectivo', label: 'Efectivo', short: 'Ef.', color: 'emerald' },
  { value: 'transferencia', label: 'Transferencia', short: 'Transf.', color: 'sky' },
  { value: 'cheque', label: 'Cheque', short: 'Ch.', color: 'purple' },
  { value: 'cuenta_corriente', label: 'Cuenta corriente', short: 'Cta. Cte.', color: 'amber' },
  { value: 'tarjeta', label: 'Tarjeta', short: 'Tj.', color: 'indigo' },
  { value: 'otros', label: 'Otros', short: 'Otros', color: 'slate' }
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

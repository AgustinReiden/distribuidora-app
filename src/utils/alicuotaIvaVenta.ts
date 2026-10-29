import type { CondicionIva } from './calculations'

/** Alícuota de IVA con que se VENDE un producto (#1258). Espejo de
 *  `public._alicuota_iva_venta(condicion_iva, porcentaje_iva)`: la condición
 *  manda. Exento o no gravado → 0; gravado → su porcentaje, y 21 si no tiene
 *  (el default de la columna y de la ficha). Antes la venta hacía
 *  `porcentaje_iva ?? 21` y un exento cargado sin porcentaje (el CHECK de
 *  productos lo permite) se facturaba al 21%. El server recalcula el desglose
 *  con la misma regla: si cambiás una, cambiá la otra. */
export function alicuotaIvaVenta(
  producto?: { condicion_iva?: CondicionIva | null; porcentaje_iva?: number | null } | null,
): number {
  const condicion = producto?.condicion_iva
  if (condicion === 'exento' || condicion === 'no_gravado') return 0
  return producto?.porcentaje_iva ?? 21
}

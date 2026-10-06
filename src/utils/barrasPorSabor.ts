import type { PromoAcumuladorDB } from '../types'

/** Lo que hace falta de la promo para armar sus barras. */
export interface PromoParaBarras {
  id: string | number
  producto_regalo_id?: string | number | null
  ajuste_producto_id?: string | number | null
  usos_pendientes?: number | null
}

export type BarraSabor = PromoAcumuladorDB & { esDefault: boolean }

/**
 * Las barras de una promo de fracción: UNA POR SABOR (#840).
 *
 * Desde la mig "un contador por sabor" todos los caminos (alta, edición,
 * cancelación, salvedad, sustitución, reparto) suman y restan en la barra del
 * producto regalado, y cada sabor descuenta su propio fardo. Dónde vive cada
 * barra:
 *
 *  - la del sabor DEFAULT de la promo, en `promociones.usos_pendientes` (no
 *    tiene fila en `promo_acumuladores`, mig 221). Ya NO es la suma de todos
 *    los sabores: es sólo la de ese sabor;
 *  - la de cualquier otro sabor, en su fila de `promo_acumuladores`.
 *
 * La del default va siempre primero (aunque esté en 0, es la promo); las de
 * los otros sabores, sólo si tienen un fardo abierto.
 */
export function barrasPorSabor(
  promo: PromoParaBarras,
  filas: readonly PromoAcumuladorDB[] | null | undefined,
): BarraSabor[] {
  const defaultId = promo.producto_regalo_id != null ? String(promo.producto_regalo_id) : null
  const barras: BarraSabor[] = []

  if (defaultId) {
    barras.push({
      id: `default-${promo.id}`,
      promocion_id: String(promo.id),
      producto_regalo_id: defaultId,
      ajuste_producto_id: promo.ajuste_producto_id != null ? String(promo.ajuste_producto_id) : null,
      usos_pendientes: Number(promo.usos_pendientes ?? 0),
      sucursal_id: 0,
      created_at: '',
      updated_at: '',
      esDefault: true,
    })
  }

  for (const fila of filas ?? []) {
    // Defensa: la mig 221 garantiza que el default no tiene fila. Si
    // apareciera, la verdad es la de `promociones`.
    if (defaultId !== null && String(fila.producto_regalo_id) === defaultId) continue
    if (Number(fila.usos_pendientes) > 0) {
      barras.push({ ...fila, usos_pendientes: Number(fila.usos_pendientes), esDefault: false })
    }
  }

  return barras
}

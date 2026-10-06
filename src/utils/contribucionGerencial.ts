/**
 * Contribución estimada del reporte gerencial: la ÚNICA definición.
 *
 *   contribución = margen neto − mermas − comisión − notas de crédito de venta
 *
 * La usan las cards (período y comparativo) y el waterfall. `reporte_gerencial`
 * no la calcula: devuelve las piezas en `kpis`, y la comisión sale del front
 * (reglas de `calcular_comisiones` o el simulador de % plano).
 *
 * Las notas de crédito de venta (#845, mig 289) NO tocan los márgenes —son un
 * crédito reconocido después de la venta, por la fecha de la nota— pero sí la
 * contribución: es plata que el negocio le devuelve al cliente. Opcional por
 * compat con respuestas cacheadas del RPC anterior (sin la clave = 0).
 */
export interface PiezasContribucion {
  margen_neto: number
  mermas: number
  notas_credito_venta?: number
}

export function contribucionEstimada(k: PiezasContribucion, comision: number): number {
  return (Number(k.margen_neto) || 0)
    - (Number(k.mermas) || 0)
    - (Number(comision) || 0)
    - (Number(k.notas_credito_venta) || 0)
}

/**
 * Cobranza del período en sus tres partes (#845): plata cobrada, crédito no
 * dinerario aplicado (NC y adelantos de sueldo) y pendiente. `pctCobrado` es
 * SÓLO plata sobre la venta. `credito_aplicado` opcional por compat con cache.
 */
export function resumenCobranza(
  c: { cobrado: number; pendiente: number; credito_aplicado?: number },
  venta: number,
): { cobrado: number; creditoAplicado: number; pendiente: number; pctCobrado: number } {
  const cobrado = Number(c.cobrado) || 0
  const creditoAplicado = Number(c.credito_aplicado) || 0
  const pendiente = Number(c.pendiente) || 0
  return { cobrado, creditoAplicado, pendiente, pctCobrado: venta ? cobrado / venta : 0 }
}

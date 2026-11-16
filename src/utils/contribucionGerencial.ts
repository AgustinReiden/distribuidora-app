/**
 * Contribución estimada del reporte gerencial: la ÚNICA definición.
 *
 *   contribución = margen neto − mermas − comisión − notas de crédito aparte
 *
 * La usan las cards (período y comparativo) y el waterfall. `reporte_gerencial`
 * no la calcula: devuelve las piezas en `kpis`, y la comisión sale del front
 * (reglas de `calcular_comisiones` o el simulador de % plano).
 *
 * Las notas de crédito de venta (#845, mig 289) son plata que el negocio le
 * devuelve al cliente, por la fecha de la nota. Desde REP-D (#1545, decisión del
 * dueño) la venta del RPC ya es neta de ellas, y con la venta también el margen:
 * restarlas otra vez las contaría dos veces. El RPC que las resta manda
 * `venta_bruta`; uno anterior (o una respuesta cacheada) no la manda, y ahí se
 * siguen restando acá. Ver `notasCreditoAparte`.
 */
export interface PiezasContribucion {
  margen_neto: number
  mermas: number
  notas_credito_venta?: number
  /** Venta antes de las notas de crédito (REP-D). Si viene, `margen_neto` ya las restó. */
  venta_bruta?: number
}

/**
 * Las notas de crédito de venta que la contribución tiene que restar aparte: todas
 * con un RPC anterior a REP-D (sin `venta_bruta`), ninguna con uno que ya las restó
 * de la venta y del margen. Sin la clave de NC (cache pre-289), 0.
 */
export function notasCreditoAparte(k: Pick<PiezasContribucion, 'notas_credito_venta' | 'venta_bruta'>): number {
  if (k.venta_bruta != null) return 0
  return Number(k.notas_credito_venta) || 0
}

export function contribucionEstimada(k: PiezasContribucion, comision: number): number {
  return (Number(k.margen_neto) || 0)
    - (Number(k.mermas) || 0)
    - (Number(comision) || 0)
    - notasCreditoAparte(k)
}

/**
 * Cobranza del período en sus tres partes (#845): plata cobrada, crédito no
 * dinerario aplicado (NC y adelantos de sueldo) y pendiente. `pctCobrado` es
 * SÓLO plata sobre lo cobrado + aplicado + pendiente (Σ total, con el envío). `credito_aplicado` opcional por compat con cache.
 */
export function resumenCobranza(
  c: { cobrado: number; pendiente: number; credito_aplicado?: number },
): { cobrado: number; creditoAplicado: number; pendiente: number; pctCobrado: number } {
  const cobrado = Number(c.cobrado) || 0
  const creditoAplicado = Number(c.credito_aplicado) || 0
  const pendiente = Number(c.pendiente) || 0
  // El denominador es lo que se cobró, se aplicó o falta: igual a Σ total de los pedidos, con el
  // envío cobrado adentro. `venta` (sólo productos) lo dejaría pasar de 100 %.
  const base = cobrado + creditoAplicado + pendiente
  return { cobrado, creditoAplicado, pendiente, pctCobrado: base ? cobrado / base : 0 }
}

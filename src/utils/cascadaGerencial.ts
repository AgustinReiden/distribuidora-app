/**
 * Los pasos del gráfico en cascada del gerencial (venta → contribución), sin dibujar nada.
 *
 * Vive acá y no en `charts.tsx` para poder probarlo: el gráfico sólo mapea cada `tono` a un color.
 *
 * El margen comercial del server nuevo se calcula sólo sobre lo vendido que tiene costo, y manda
 * aparte lo vendido sin costo (`kpis.ingreso_sin_costo`, 1562-b6). Para que la cascada cierre con la
 * tarjeta de margen, entre el CMV y el margen va un paso «− Sin costo». Sin ese dato (o en 0) la
 * cascada queda como siempre: venta − CMV (+ descuentos) = margen comercial.
 *
 * Cuánto de lo sin costo quedó fuera del margen lo dice `sinCostoFueraDelMargen`
 * (`margenSobreConCosto.ts`): una sola regla, la que usan las tarjetas de margen. Puede ser
 * NEGATIVO (una nota de crédito sobre un producto sin costo que supera su venta): el server lo resta
 * igual del margen, así que acá también (paso «+ Sin costo») y la cascada sigue cerrando.
 */
import { contribucionEstimada } from './contribucionGerencial'

export type TonoCascada = 'blue' | 'red' | 'emerald' | 'cyan'

export interface PasoCascada {
  /** Rótulo del eje. */
  l: string
  /** Monto con signo: lo que muestra el tooltip. */
  v: number
  /** Rango [desde, hasta] de la barra flotante. */
  r: [number, number]
  tono: TonoCascada
}

export interface EntradaCascada {
  venta: number
  cmv: number
  bonif: number
  mermas: number
  comision: number
  /** Descuentos de proveedores (mig 280): restan del lado del costo. */
  descuentos?: number
  /** Notas de crédito de venta que la contribución resta aparte (`notasCreditoAparte`). */
  notasCredito?: number
  /**
   * Venta de líneas sin costo que el server dejó FUERA del margen (`sinCostoFueraDelMargen`: 0 con
   * un server anterior, que todavía la contaba como margen). Con signo: puede ser negativa.
   */
  sinCosto?: number
}

export function pasosCascada(e: EntradaCascada): { pasos: PasoCascada[]; contrib: number } {
  const descuentos = e.descuentos ?? 0
  const sinCosto = Number.isFinite(e.sinCosto) ? (e.sinCosto as number) : 0
  const notasCredito = e.notasCredito ?? 0
  const trasCmv = e.venta - e.cmv
  const trasSinCosto = trasCmv - sinCosto
  const mc = trasSinCosto + descuentos
  const mn = mc - e.bonif
  // Misma definición que la card (#845): las NC de venta que van aparte restan acá, no en los márgenes.
  const contrib = contribucionEstimada({ margen_neto: mn, mermas: e.mermas, notas_credito_venta: notasCredito }, e.comision)
  const trasComision = mn - e.mermas - e.comision
  const pasos: PasoCascada[] = [
    { l: 'Venta', v: e.venta, r: [0, e.venta], tono: 'blue' },
    { l: '− CMV', v: -e.cmv, r: [trasCmv, e.venta], tono: 'red' },
    // Barra flotante entre los dos niveles, en orden: con un sin costo negativo sube en vez de bajar.
    ...(sinCosto ? [{
      l: sinCosto > 0 ? '− Sin costo' : '+ Sin costo',
      v: -sinCosto,
      r: [Math.min(trasSinCosto, trasCmv), Math.max(trasSinCosto, trasCmv)] as [number, number],
      tono: sinCosto > 0 ? 'red' as const : 'emerald' as const,
    }] : []),
    ...(descuentos ? [{ l: '+ Desc. prov.', v: descuentos, r: [trasSinCosto, mc] as [number, number], tono: 'emerald' as const }] : []),
    { l: 'Mg comerc.', v: mc, r: [0, mc], tono: 'cyan' },
    { l: '− Bonif.', v: -e.bonif, r: [mn, mc], tono: 'red' },
    { l: '− Mermas', v: -e.mermas, r: [mn - e.mermas, mn], tono: 'red' },
    { l: '− Comis.', v: -e.comision, r: [trasComision, mn - e.mermas], tono: 'red' },
    ...(notasCredito ? [{ l: '− Notas de crédito', v: -notasCredito, r: [contrib, trasComision] as [number, number], tono: 'red' as const }] : []),
    { l: 'Contrib.', v: contrib, r: [0, contrib], tono: 'emerald' },
  ]
  return { pasos, contrib }
}

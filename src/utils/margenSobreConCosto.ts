/**
 * El porcentaje de un margen del reporte gerencial, sobre el ingreso CON costo (1562-b6, #1562).
 *
 * Decisión del dueño (D42): una línea sin costo se excluye del margen y se muestra aparte, igual en
 * todos los reportes. Si el margen ya no la cuenta, el porcentaje tampoco puede dividir por ella:
 * Rentabilidad divide por el ingreso con costo, y el gerencial hace lo mismo. Venta 1.000, sin
 * costo 100, CMV 600: margen 300, 33,3 % (no 30 %).
 *
 * `sinCosto` es lo que el RPC dejó fuera del margen. Un RPC anterior a 1562-b6 todavía lo contaba
 * adentro: ahí se pasa 0 (ver `sinCostoFueraDelMargen`).
 *
 * Con un denominador 0 o negativo (todo sin costo, o un período cuyas notas de crédito superan la
 * venta) el porcentaje no tiene sentido: devuelve null y la pantalla muestra «—».
 */
export function margenSobreConCosto(margen: number, venta: number, sinCosto = 0): number | null {
  const base = (Number(venta) || 0) - (Number(sinCosto) || 0)
  if (!(base > 0)) return null
  return (Number(margen) || 0) / base
}

/**
 * Lo que el RPC dejó fuera de los márgenes por no tener costo: el `ingreso_sin_costo` que manda,
 * si es un RPC con 1562-b6 (trae `venta_bruta`, de la misma migración), o 0 si es uno anterior,
 * que todavía lo contaba como margen.
 */
export function sinCostoFueraDelMargen(k: { venta_bruta?: number }, sinCosto: number | undefined): number {
  if (k.venta_bruta == null) return 0
  return Number(sinCosto) || 0
}

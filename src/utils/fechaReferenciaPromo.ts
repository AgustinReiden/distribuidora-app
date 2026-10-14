import { fechaLocalISO } from './formatters'

/** Fecha con la que se resuelven las promos de un pedido: la del pedido,
 *  topada a hoy (mismo v_d que regalo_fuera_de_promo, #1152). Devuelve
 *  undefined para hoy o una fecha futura: así el queryKey sigue siendo
 *  'today' y el cache (y el uso offline) no cambian en el caso normal. */
export function fechaReferenciaPromo(fecha?: string | null, hoy = fechaLocalISO()): string | undefined {
  const f = fecha?.slice(0, 10)
  return f && f < hoy ? f : undefined
}

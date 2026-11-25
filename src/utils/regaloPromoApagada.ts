/**
 * promos-B6 (tanda 6 de #1603), decisión del dueño (24/11): al editar un pedido, el regalo
 * de una promo que ya no rige (el admin la apagó) se CONSERVA pero NO CRECE. V×10 + R×4 con
 * la promo apagada, editado a V×20, sigue con R×4 (no R×8). Bajar la venta lo recorta como
 * siempre: el tope de las reglas sigue valiendo.
 *
 * Espejo de `regalo_fuera_de_promo` (paso 4, en la edición): «rige» es el mismo predicado
 * de su paso 2b, activa y vigente en LEAST(fecha del pedido, hoy) o en hoy. Lo guardado se
 * mide en cortes, la unidad de la promo. El admin no pasa por ahí (el server lo exime).
 */

export interface PromoVigencia {
  activo?: boolean | null
  fecha_inicio?: string | null
  fecha_fin?: string | null
}

const vigenteEn = (p: PromoVigencia, dia: string) =>
  !!p.fecha_inicio && p.fecha_inicio <= dia && (!p.fecha_fin || p.fecha_fin >= dia)

/** ¿La promo rige para este pedido? `fechaPedido` y `hoy` en 'YYYY-MM-DD'. */
export function promoRigeEnPedido(promo: PromoVigencia, fechaPedido: string | null | undefined, hoy: string): boolean {
  if (!promo.activo) return false
  const d = fechaPedido && fechaPedido < hoy ? fechaPedido : hoy
  return vigenteEn(promo, d) || vigenteEn(promo, hoy)
}

/**
 * La cantidad de regalo que puede llevar el pedido editado: la que da la promo, o, si la
 * promo ya no rige, a lo sumo lo que el pedido ya tenía (`conservado`, en cortes). Sin la
 * promo (no se sabe), la que da la promo: decide el server.
 */
export function regaloQueNoCrece(args: {
  cantidad: number
  promo: PromoVigencia | null | undefined
  fechaPedido: string | null | undefined
  hoy: string
  conservado: number
}): number {
  if (!args.promo || promoRigeEnPedido(args.promo, args.fechaPedido, args.hoy)) return args.cantidad
  return Math.min(args.cantidad, Math.max(Math.floor(args.conservado), 0))
}

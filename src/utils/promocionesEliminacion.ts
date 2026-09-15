/**
 * Decisión de si una promoción se puede borrar directamente desde el panel.
 *
 * Las FKs de `promociones` NO son RESTRICT como las de `clientes` (mig 200):
 * `pedido_items.promocion_id` es ON DELETE SET NULL y `promo_ajustes.promocion_id`
 * es ON DELETE CASCADE. Un DELETE nunca falla, pero borra en silencio el
 * historial de ajustes de stock y desprende la promo de los pedidos ya
 * facturados, que dejan de saber con qué promo se vendieron. Por eso se cuenta
 * ANTES de ofrecer "Eliminar", igual que con clientes.
 */
export interface ReferenciasPromocion {
  pedidos: number
  ajustes: number
}

export function tienePromocionUso(referencias: ReferenciasPromocion): boolean {
  return referencias.pedidos > 0 || referencias.ajustes > 0
}

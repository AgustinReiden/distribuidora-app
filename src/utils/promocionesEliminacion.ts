/**
 * Decisión de si una promoción se puede borrar directamente desde el panel.
 *
 * Las FKs de `promociones` NO son RESTRICT como las de `clientes` (mig 200):
 * `pedido_items.promocion_id` y `salvedades_items.promocion_id` son ON DELETE
 * SET NULL y `promo_ajustes.promocion_id` es ON DELETE CASCADE. Borrarla
 * desprende la promo de los pedidos (el regalo de un pedido abierto queda sin
 * promo y al cancelarlo no vuelve al stock) y borra en silencio el historial de
 * ajustes de stock. Por eso se cuenta ANTES de ofrecer "Eliminar", y con uso se
 * ofrece desactivarla (decisión del dueño, D1 del plan #1603).
 *
 * El server dice lo mismo (#1556, 1556-b1): `trg_promocion_no_se_borra_con_uso`
 * rechaza el DELETE de una promo con líneas de pedido, ajustes o salvedades.
 * Si se cambia la regla de un lado, se cambia del otro.
 */
export interface ReferenciasPromocion {
  pedidos: number
  ajustes: number
  /** Salvedades con la promo: una sobre el regalo lo borra de `pedido_items`. */
  salvedades: number
}

export function tienePromocionUso(referencias: ReferenciasPromocion): boolean {
  return referencias.pedidos > 0 || referencias.ajustes > 0 || referencias.salvedades > 0
}

/** Lo que tiene la promo, en palabras: "3 pedidos facturados y 1 ajuste de stock". */
export function detalleDeUso(referencias: ReferenciasPromocion): string {
  const detalle: string[] = []
  if (referencias.pedidos > 0) {
    detalle.push(`${referencias.pedidos} ${referencias.pedidos === 1 ? 'pedido facturado' : 'pedidos facturados'}`)
  }
  if (referencias.ajustes > 0) {
    detalle.push(`${referencias.ajustes} ${referencias.ajustes === 1 ? 'ajuste' : 'ajustes'} de stock`)
  }
  if (referencias.salvedades > 0) {
    detalle.push(`${referencias.salvedades} ${referencias.salvedades === 1 ? 'salvedad' : 'salvedades'}`)
  }
  if (detalle.length <= 1) return detalle.join('')
  return `${detalle.slice(0, -1).join(', ')} y ${detalle[detalle.length - 1]}`
}

/**
 * El mensaje de un borrado que falló. El rechazo de la guarda del server (un
 * RAISE, código P0001) ya está escrito para el usuario: dice qué usa la promo y
 * que se desactive. Cualquier otro error del server no se muestra crudo.
 */
export function mensajeAlNoBorrarPromocion(error: unknown): string {
  const e = error as { code?: unknown; message?: unknown } | null | undefined
  if (e?.code === 'P0001' && typeof e.message === 'string' && e.message.trim() !== '') {
    return e.message
  }
  return 'Error al eliminar promoción'
}

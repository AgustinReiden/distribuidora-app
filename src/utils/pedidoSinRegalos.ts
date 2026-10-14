/**
 * "Sincronizar sin el regalo" (#1153): el payload de un alta encolada sin sus
 * líneas de regalo.
 *
 * Cuando el replay offline recibe el rechazo `regalo_fuera_de_promo` (la promo
 * se apagó, venció o cambió mientras el pedido esperaba en el teléfono), el
 * preventista puede decidir mandarlo sin el regalo. El server no dice qué
 * regalo falló, así que se quitan TODOS (también los de otra promo que seguía
 * legal): el texto del botón lo avisa.
 *
 * No se tocan los totales: el regalo va a precio 0 (CHECK
 * `pedido_items_regalo_a_precio_cero`, mig 363), así que no suma a `total`,
 * `totalNeto` ni `totalIva`. Tampoco `offlineUuid`: el rechazo no selló la
 * clave (`crear_pedido_idempotente` sólo sella con success), y reusarla es lo
 * que impide duplicar el pedido si el reintento se corta a mitad de camino.
 */
export function quitarRegalosDelPayload(payload: Record<string, unknown>): Record<string, unknown> | null {
  const items = Array.isArray(payload.items) ? (payload.items as Array<Record<string, unknown>>) : []
  const sinRegalo = items.filter(item => item?.esBonificacion !== true)
  if (sinRegalo.length === items.length) return null

  const origenes = Array.isArray(payload.origenes)
    ? (payload.origenes as Array<Record<string, unknown>>).filter(o => o?.es_bonificacion !== true)
    : payload.origenes

  return {
    ...payload,
    items: sinRegalo,
    ...(payload.origenes !== undefined ? { origenes } : {}),
    regalosQuitados: true,
  }
}

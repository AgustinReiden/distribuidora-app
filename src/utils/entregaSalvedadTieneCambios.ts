/**
 * ¿Cerrar ahora el modal de entrega con salvedad tira trabajo a la basura?
 *
 * Decide si Escape cierra o no (WP-26a le dio a `ModalBase` el
 * `onEscapeKeyDown` para eso). La X y "Cancelar" cierran siempre: son un
 * click deliberado. Escape se aprieta sin querer, y el modal hecho a mano no
 * cerraba con él: habilitarlo sin condición le haría perder al transportista
 * lo que ya cargó en la puerta del cliente.
 *
 * - Sin nada tildado, cerrar no pierde nada: se cierra.
 * - Con al menos un ítem tildado hay cantidad, motivo o descripción cargados.
 * - En el paso de confirmación siempre hay algo tildado (no se llega sin), y
 *   además puede haber un guardado en vuelo: se lo trata aparte para no
 *   depender de esa regla del paso 1.
 */
export type PasoEntregaSalvedad = 'seleccion' | 'confirmacion'

export interface EstadoEntregaSalvedad {
  paso: PasoEntregaSalvedad
  /** Cuántos ítems del pedido están tildados como "con salvedad". */
  seleccionados: number
}

export function entregaSalvedadTieneCambios({ paso, seleccionados }: EstadoEntregaSalvedad): boolean {
  return paso === 'confirmacion' || seleccionados > 0
}

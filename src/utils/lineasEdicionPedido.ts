/**
 * Cuándo la edición de un pedido vuelve a arrancar sus líneas desde lo guardado
 * (FRV-1, #1598).
 *
 * `ModalEditarPedido` arma las líneas editables desde `pedido.items`, y antes lo
 * rehacía cada vez que cambiaba la identidad de `pedido` o de `productos`. Las dos
 * cambian sin que el pedido guardado cambie: reasignar el preventista desde el mismo
 * modal copia el pedido, y la lista de productos se vuelve a pedir al reconectar o
 * al vaciarse la cola offline. Cada vez, un 10 bajado a 8 volvía a 10 sin aviso.
 *
 * La regla: las líneas se rehacen cuando es otro pedido o cuando cambió lo que el
 * pedido tiene guardado (la versión nueva tras guardar). Un refresco de datos que
 * deja las líneas guardadas iguales sólo las rehace si el usuario no tocó nada
 * (sirve, por ejemplo, para que el precio manual se marque bien si los productos
 * llegaron después de abrir).
 */

/** Lo de una línea guardada que usa la edición para armar sus filas. */
export interface LineaGuardada {
  id?: string | number | null
  producto_id: string | number | null
  cantidad: number | string
  precio_unitario: number | string
  es_bonificacion?: boolean | null
  combo_id?: string | number | null
  precio_sin_combo_unitario?: number | string | null
  origen_precio?: string | null
  promocion_id?: string | number | null
}

/** Con qué se armaron las líneas de la edición la última vez. */
export interface InicioDeLineas {
  pedidoId: string
  huella: string
}

/** La huella de lo que el pedido tiene guardado: si no cambia, es la misma versión. */
export function huellaLineasGuardadas(lineas: readonly LineaGuardada[]): string {
  return JSON.stringify(lineas.map(l => [
    l.id == null ? null : String(l.id),
    l.producto_id == null ? null : String(l.producto_id),
    Number(l.cantidad),
    Number(l.precio_unitario),
    l.es_bonificacion === true,
    l.combo_id == null ? null : String(l.combo_id),
    l.precio_sin_combo_unitario == null ? null : Number(l.precio_sin_combo_unitario),
    l.origen_precio ?? null,
    l.promocion_id == null ? null : String(l.promocion_id),
  ]))
}

/**
 * ¿Hay que volver a armar las líneas desde lo guardado?
 * - la primera vez, otro pedido o otra versión guardada: sí;
 * - el mismo pedido con las mismas líneas guardadas: sólo si no hay cambios sin guardar.
 */
export function debeReiniciarLineas(
  previo: InicioDeLineas | null,
  actual: InicioDeLineas,
  hayCambiosSinGuardar: boolean,
): boolean {
  if (!previo) return true
  if (previo.pedidoId !== actual.pedidoId || previo.huella !== actual.huella) return true
  return !hayCambiosSinGuardar
}

/**
 * ¿El pedido está dado de baja? La baja de un pedido es `cancelado`, y nada
 * más (#1520, decisión del dueño): desde la mig 487 `pedidos_estado_check` no
 * admite `anulado`. Este es el predicado del lado del front.
 */
export function esPedidoDeBaja(estado: string | null | undefined): boolean {
  return estado === 'cancelado'
}

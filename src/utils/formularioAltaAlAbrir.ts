/**
 * La fecha del formulario de «Nuevo pedido» al abrirlo (frv-B1, tanda 6 de #1603).
 *
 * El formulario nace con `fechaLocalISO()` al montar /pedidos y sólo se renueva al cerrar o
 * crear un alta. Una pantalla que se deja abierta de un día para el otro abría «Nuevo pedido»
 * con la fecha de ayer: para quien no es admin cae dentro de la ventana y el server la acepta,
 * así que la venta y la promo se medían en el día equivocado sin que nada fallara.
 *
 * Al abrir el alta, un formulario todavía en blanco (sin cliente, sin renglones ni notas) toma
 * el día de hoy. Uno con algo cargado no se toca: es trabajo del usuario, y la fecha distinta
 * a hoy ya se le muestra con su aviso ámbar.
 */
export function formularioAltaAlAbrir<T extends {
  clienteId: string
  items: readonly unknown[]
  notas: string
  fecha: string
}>(actual: T, hoy: string): T {
  if (actual.fecha === hoy) return actual
  if (actual.clienteId || actual.items.length > 0 || actual.notas) return actual
  return { ...actual, fecha: hoy }
}

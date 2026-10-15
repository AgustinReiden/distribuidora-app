import type { ClienteDB } from '../types'

/**
 * ¿Puede este usuario OPERAR con el cliente? (tomarle un pedido, marcarle una
 * visita, editarlo desde el panel, contarlo como "suyo").
 *
 * No es lo mismo que verlo. Desde la mig 358 la RLS le muestra al preventista,
 * además de los suyos, todo cliente al que ya le vendió —aunque hoy lo atienda
 * otro o esté reservado a administración— para que sus pedidos viejos no
 * pierdan el cliente. Esos son historial: se ven por el embed del pedido, no en
 * los listados operativos. Ésta es la regla de operar, espejo de la rama de
 * operar de `mt_clientes_select` y de `trg_pedidos_cliente_asignado`:
 * sin asignar o asignado a él, y no reservado.
 *
 * `rol` es el rol CRUDO de perfiles (`perfil.rol`), el mismo que lee la RLS.
 * Cualquier otro rol opera con todo lo que ve. Los triggers de pedidos
 * (`pedidos_cliente_asignado` y `pedidos_cliente_reservado`) deciden con
 * `_actua_como_preventista` (#1179) y también aplican la regla a quien tiene
 * el preventista como rol extra en la sucursal. Este espejo sigue por rol base
 * a propósito: el extra no puede vender hasta que se abran los candados de rol
 * de las RPC de alta (ver el COMMENT de `perfil_roles_rol_check`).
 */
export function esClienteOperable(
  cliente: Pick<ClienteDB, 'preventista_ids' | 'reservado_admin'>,
  usuario: { rol: string | null | undefined; userId: string | null | undefined },
): boolean {
  if (usuario.rol !== 'preventista') return true
  if (!usuario.userId) return false
  if (cliente.reservado_admin) return false
  const ids = cliente.preventista_ids
  return !ids || ids.length === 0 || ids.includes(usuario.userId)
}

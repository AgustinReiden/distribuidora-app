import type { ClienteDB } from '../types'

/**
 * ¿Puede este usuario OPERAR con el cliente? (tomarle un pedido, marcarle una
 * visita, editarlo desde el panel, contarlo como "suyo").
 *
 * No es lo mismo que verlo. Desde la mig 356 la RLS le muestra al preventista,
 * además de los suyos, todo cliente al que ya le vendió —aunque hoy lo atienda
 * otro o esté reservado a administración— para que sus pedidos viejos no
 * pierdan el cliente. Esos son historial: se ven por el embed del pedido, no en
 * los listados operativos. Ésta es la regla de operar, espejo de la rama de
 * operar de `mt_clientes_select` y de `trg_pedidos_cliente_asignado`:
 * sin asignar o asignado a él, y no reservado.
 *
 * `rol` es el rol CRUDO de perfiles (`perfil.rol`), el mismo que lee la RLS.
 * Cualquier otro rol opera con todo lo que ve.
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

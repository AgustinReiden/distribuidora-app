/**
 * A quién queda asignado un cliente cuando se da de alta (FRV-2, tanda 6 de #1603; decisión del
 * dueño del 24/11). Una sola regla para las dos puertas del alta: el formulario de /clientes
 * (`ClientesContainer`) y el alta rápida del pedido (`PedidosContainer`).
 *
 * «Sin asignar» significa visible para TODOS los preventistas (mig 028): un cliente que un
 * preventista da de alta tiene que quedar asignado a él, no suelto. Un reservado a admin
 * (mig 214) no lleva preventistas. Desde la 378 sólo quien actúa como preventista puede tener
 * clientes asignados: el encargado no se auto-asigna (el trigger de `cliente_preventistas` lo
 * rechazaría).
 *
 * Devuelve `undefined` cuando quien da el alta no toca las asignaciones (el encargado, el
 * transportista): no se manda nada. Sólo el admin elige los de `baseIds`; el preventista suma
 * el suyo a lo que haya.
 */
export function preventistaIdsDelAlta(entrada: {
  isAdmin: boolean
  isPreventista: boolean
  userId?: string | null
  baseIds?: string[] | null
  reservadoAdmin?: boolean
}): string[] | undefined {
  const { isAdmin, isPreventista, userId, baseIds, reservadoAdmin } = entrada
  const seAutoAsigna = isPreventista && !isAdmin && !!userId
  if (!isAdmin && !seAutoAsigna) return undefined
  // Reservado: sin asignaciones, y sin la auto-asignación del que lo crea.
  if (reservadoAdmin) return []
  const base = baseIds ?? []
  return seAutoAsigna ? Array.from(new Set([...base, userId as string])) : base
}

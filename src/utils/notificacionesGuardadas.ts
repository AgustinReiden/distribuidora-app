/**
 * Las notificaciones guardadas en el teléfono son del usuario que las vio (INF-5,
 * #1563).
 *
 * Llevan montos y nombres de clientes. Antes vivían bajo una clave global
 * (`notifications`) y sobrevivían al logout: el siguiente usuario de ese teléfono
 * veía las del anterior. Ahora van bajo `notifications:<usuario>`, sin usuario no
 * se guardan (quedan en memoria), y el logout borra las del que sale.
 *
 * El dueño lo fija la sesión (`useAuth`), como las claves de los cobros (#1410):
 * así `NotificationProvider` no depende de `AuthProvider`, y los tests que lo
 * montan solo siguen andando.
 */

/** La clave global de antes: no se sabe de quién es, así que no se migra. */
export const CLAVE_NOTIFICACIONES_VIEJA = 'notifications'

const PREFIJO = 'notifications:'

export function claveNotificaciones(usuarioId: string): string {
  return `${PREFIJO}${usuarioId}`
}

let usuarioActual: string | null = null
const oyentes = new Set<() => void>()

/** Lo llama la sesión (`useAuth`) cada vez que cambia el usuario. */
export function fijarUsuarioNotificaciones(usuarioId: string | null): void {
  if (usuarioId === usuarioActual) return
  usuarioActual = usuarioId
  oyentes.forEach(f => f())
}

export function usuarioNotificaciones(): string | null {
  return usuarioActual
}

export function suscribirUsuarioNotificaciones(oyente: () => void): () => void {
  oyentes.add(oyente)
  return () => { oyentes.delete(oyente) }
}

/** Borra del teléfono las notificaciones de un usuario, y las de la clave vieja (logout). */
export function olvidarNotificacionesDe(usuarioId: string | null): void {
  try {
    if (usuarioId) localStorage.removeItem(claveNotificaciones(usuarioId))
    localStorage.removeItem(CLAVE_NOTIFICACIONES_VIEJA)
  } catch {
    // Sin storage no hay nada guardado que borrar.
  }
}

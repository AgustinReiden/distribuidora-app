/**
 * Quién es el usuario de la sesión para los avisos, y la limpieza de las
 * notificaciones que se guardaban en el teléfono (INF-5, #1563; INF-1, #1600).
 *
 * Las notificaciones guardadas se borraron (nada las leía: INF-1): los avisos que
 * tienen que leerse quedan en pantalla hasta que se cierran. Pero versiones
 * anteriores las dejaron en `localStorage`, con montos y nombres de clientes, bajo
 * la clave global `notifications` y bajo `notifications:<usuario>`. Hoy no se
 * escribe ninguna: `olvidarNotificacionesGuardadas` borra las que quedaron, al
 * montar la app y al cerrar sesión.
 *
 * El dueño de la sesión lo fija `useAuth`, como las claves de los cobros (#1410):
 * así `NotificationProvider` no depende de `AuthProvider`, y los tests que lo
 * montan solo siguen andando. Lo usa para no mostrarle al usuario que entra los
 * avisos fijos del anterior.
 */

const PREFIJO = 'notifications'

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

/** Borra del teléfono toda notificación guardada, de cualquier usuario (incluida la clave global vieja). */
export function olvidarNotificacionesGuardadas(): void {
  try {
    const claves: string[] = []
    for (let i = 0; i < localStorage.length; i++) {
      const clave = localStorage.key(i)
      if (clave && (clave === PREFIJO || clave.startsWith(`${PREFIJO}:`))) claves.push(clave)
    }
    for (const clave of claves) localStorage.removeItem(clave)
  } catch {
    // Sin storage no hay nada guardado que borrar.
  }
}

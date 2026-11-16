/**
 * Lo que no tiene que sobrevivir al cierre de una sesión en el teléfono.
 *
 * Vivía dentro de `useAuth`, así que sólo el logout y el SIGNED_OUT lo corrían:
 * `signOutLocal` (refresh fallido, perfil que falta, error del arranque) y el
 * «Iniciar sesión» del `ErrorBoundary` dejaban en el teléfono las rutas, los
 * cobros sin confirmar y el caché de lo que se vio en pantalla (1600-b7, #1600).
 * Ahora lo corren todos los caminos que sacan al usuario.
 */
import { queryClient } from './queryClient'
import { olvidarRuta, olvidarTodasLasRutas } from './rutaOfflineCache'
import { limpiarCachesDeLectura } from './offlineDb'
import { SUCURSAL_STORAGE_KEY } from './sucursalStorageKey'
import { olvidarRequestIdsDe } from '../utils/requestIdPersistente'
import { olvidarNotificacionesGuardadas } from '../utils/notificacionesGuardadas'
import { logger } from '../utils/logger'

function leerSucursalActiva(): number | null {
  try {
    const raw = localStorage.getItem(SUCURSAL_STORAGE_KEY)
    if (!raw) return null
    const id = Number(raw)
    return Number.isFinite(id) ? id : null
  } catch {
    return null
  }
}

/**
 * Borra del dispositivo lo que no tiene que sobrevivir al logout: la ruta
 * del chofer (nombres, direcciones, teléfonos y montos a cobrar en
 * localStorage), el cache de TanStack Query (todo lo que se vio en pantalla:
 * clientes, saldos, pedidos), los caches de lectura de Dexie, las claves de
 * reintento de sus cobros y las notificaciones que hubieran quedado guardadas.
 *
 * `usuarioId` puede ser null (el `ErrorBoundary` no sabe quién era): se barren
 * igual las rutas de todos y las notificaciones, y se limpia el caché.
 *
 * NO toca `pendingOperations` (la cola offline): FE-1 decidió que sobrevive
 * al logout y se oculta por usuario en la UI, no se descarta acá.
 */
export function limpiarDatosSensiblesLocales(usuarioId: string | null): void {
  if (usuarioId) {
    olvidarRuta(leerSucursalActiva(), usuarioId)
  }
  // Barrido por si quedó la ruta de otro chofer en un dispositivo compartido.
  olvidarTodasLasRutas()

  queryClient.clear()

  // Las claves de reintento de sus cobros y los cobros sin confirmar (#1410).
  olvidarRequestIdsDe(usuarioId)

  // Las notificaciones guardadas llevan montos y nombres de clientes (INF-5).
  olvidarNotificacionesGuardadas()

  limpiarCachesDeLectura().catch(err => {
    logger.warn('[useAuth] No se pudo limpiar el cache offline:', err)
  })
}

/**
 * ¿Esto falló porque el servidor dijo que no, o porque no hubo servidor?
 *
 * Es la distinción que separa "esta sesión no vale" de "no se pudo preguntar",
 * y de ella depende si se descarta algo que estaba bien. La usan el arranque de
 * la sesión (useAuth) y la carga de sucursales (SucursalContext): las dos
 * cosas que bloquean el arranque de la app y que, al fallar por red, dejaban al
 * preventista en la pantalla de login o en "sin sucursal" — sin señal para
 * arreglarlo y sin poder usar nada de lo que la app tiene para trabajar
 * offline.
 */
import { isTransientNetworkError } from './retryWithBackoff'
import { getErrorMessage } from './errorHandling'

export function esFalloDeRed(err: unknown): boolean {
  if (typeof navigator !== 'undefined' && navigator.onLine === false) return true
  if (isTransientNetworkError(err)) return true
  // `withTimeout` dice "timed out after Nms", que no matchea la heurística de
  // isTransientNetworkError. Y un timeout es el no-servidor típico del reparto:
  // la señal está pero no alcanza para completar la request.
  return /timed out/i.test(getErrorMessage(err))
}

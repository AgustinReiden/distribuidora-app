/**
 * Corre una escritura online idempotente (cobros, imputaciones, salvedades) con
 * plazo de red y reintento ante un fallo de red (#1366).
 *
 * Con señal que no pasa datos el request no falla: queda colgado hasta que corta
 * el navegador, y el modal queda en "procesando" sin que el chofer sepa si el
 * cobro entró. El `fetch` global no lleva plazo a propósito (cortaría subidas y
 * descargas largas), así que el plazo va acá, por intento, igual que en el replay
 * de la cola (`useOfflineSync`).
 *
 * Cortar del lado del que llama NO cancela lo que ya llegó al server: la
 * escritura puede haber entrado. Por eso un plazo vencido sale como
 * `ErrorDeSupabase` con `mensajeSinConexion`, que tiene que decir que se revise
 * antes de reintentar, y no se repite solo: ya se esperó lo que había que esperar.
 * Tampoco se repite un 5xx de gateway (el `code` `HTTP_5xx` no es de red): lo
 * contestó alguien, así que el server pudo haber seguido con la transacción, y
 * repetirlo sólo atrasa el aviso de que hay que revisar.
 */
import { conPlazoDeRed, isTransientNetworkError, PlazoDeRedVencido, retryWithBackoff } from './retryWithBackoff'
import { errorDeSupabase } from './errorDeSupabase'

/** Lo mismo que espera el replay de la cola por intento (`PLAZO_INTENTO_REPLAY_MS`). */
export const PLAZO_ESCRITURA_MS = 20_000

interface OpcionesEscritura {
  /**
   * `false` para una RPC sin `client_request_id`: repetirla podría duplicar el
   * efecto, así que tiene el plazo pero un solo intento.
   */
  reintentar?: boolean
}

export async function escrituraIdempotente<T>(
  llamar: (signal: AbortSignal) => Promise<T>,
  mensajeSinConexion: string,
  { reintentar = true }: OpcionesEscritura = {},
): Promise<T> {
  return retryWithBackoff(
    () => conPlazoDeRed(llamar, PLAZO_ESCRITURA_MS),
    {
      maxAttempts: reintentar ? 3 : 1,
      shouldRetry: error => isTransientNetworkError(error) && !(error instanceof PlazoDeRedVencido),
    },
  ).catch((error: unknown) => {
    // El plazo vencido trae "Sin respuesta del servidor en 20 s", que no dice qué
    // hacer: se traduce al mensaje de la operación.
    return Promise.reject(error instanceof PlazoDeRedVencido ? errorDeSupabase(error, mensajeSinConexion) : error)
  })
}

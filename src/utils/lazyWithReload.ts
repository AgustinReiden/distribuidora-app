/**
 * lazyWithReload / importConRecarga — resiliencia ante chunks obsoletos tras un deploy.
 *
 * Problema: la app vieja en memoria pide un chunk con el hash viejo
 * (`Container-<hashViejo>.js` / `pdfExport-<hashViejo>.js`) que el server ya no
 * tiene porque hubo un deploy nuevo → el import() dinámico falla con "Failed to
 * fetch dynamically imported module". En React.lazy el <Suspense> queda
 * colgado; en un handler (ej. descargar comanda) el catch solo muestra el
 * error y no se puede usar.
 *
 * Solución: ante un fallo de carga de chunk, recargar UNA vez para traer el
 * index.html + chunks frescos. El guard por sessionStorage evita loops de
 * recarga (si tras recargar sigue fallando, propaga el error real).
 *
 * El service worker SÍ está registrado (ver `serviceWorker.ts`), con
 * `skipWaiting: false` + `clientsClaim: false`. Pero la app en memoria no es
 * siempre la del SW al mando (#1267): tras un deploy, la navegación va a la red
 * y carga el HTML nuevo con el SW viejo todavía controlando. Sus chunks los deja
 * en el precache el SW nuevo al instalarse, y la ruta de JS/CSS los busca ahí
 * cuando no hay red (`respaldoRecursoSinRed`). Lo que no cubre: un chunk que el
 * SW nuevo todavía no terminó de bajar cuando se cortó la señal.
 */
import { lazy, type ComponentType, type LazyExoticComponent } from 'react'

const RELOAD_KEY = 'chunk-reload-at'
const RELOAD_COOLDOWN_MS = 15000

export function esErrorDeChunk(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err)
  return /Failed to fetch dynamically imported module|error loading dynamically imported module|Importing a module script failed|ChunkLoadError/i.test(msg)
}

/** Cuántas recargas se permiten por sesión antes de dejar de insistir. */
const RELOAD_MAX_INTENTOS = 2

/**
 * Recarga la página para traer index.html + chunks frescos. Devuelve true si
 * disparó la recarga; false si no corresponde recargar.
 *
 * Recarga también sin conexión: sin red, la navegación sirve el index.html que
 * precacheó el propio SW (`respaldoNavegacionSinRed`, #1267), o sea un HTML
 * cuyos chunks están en el precache. Recargar offline cambia el bundle en
 * memoria por uno que el SW sí puede servir completo.
 *
 * NO recarga cuando ya se recargó `RELOAD_MAX_INTENTOS` veces: el cooldown
 * viejo era temporal, no un tope; pasados 15 s volvía a recargar, y si el
 * chunk seguía sin estar la pestaña entraba en loop de recargas.
 */
function recargarUnaVezPorChunk(): boolean {
  const [intentosRaw, lastRaw] = (sessionStorage.getItem(RELOAD_KEY) || '0|0').split('|')
  const intentos = Number(intentosRaw) || 0
  const last = Number(lastRaw) || 0

  if (intentos >= RELOAD_MAX_INTENTOS) return false
  if (Date.now() - last <= RELOAD_COOLDOWN_MS) return false

  sessionStorage.setItem(RELOAD_KEY, `${intentos + 1}|${Date.now()}`)
  window.location.reload()
  return true
}

// El genérico espeja el de React.lazy (`ComponentType<any>`): con
// `ComponentType<unknown>` no entran los componentes con props requeridas, que
// es la mayoría de los modales. Es un ensanchamiento puro, ningún call site
// existente cambia de tipo.
export function lazyWithReload<T extends ComponentType<any>>(
  factory: () => Promise<{ default: T }>,
): LazyExoticComponent<T> {
  return lazy(async () => {
    try {
      return await factory()
    } catch (err) {
      if (esErrorDeChunk(err) && recargarUnaVezPorChunk()) {
        // Promesa que nunca resuelve: mantiene el fallback hasta que recarga.
        return new Promise<{ default: T }>(() => {})
      }
      throw err
    }
  })
}

/**
 * importConRecarga — misma resiliencia que lazyWithReload pero para import()
 * dinámicos usados FUERA de React.lazy (handlers de eventos que cargan un módulo
 * bajo demanda, ej. el módulo de PDF/comandas). Si el chunk quedó obsoleto tras
 * un deploy, recarga la app una vez; al reintentar la acción el import resuelve.
 * Lanza un error amistoso para que el catch del handler muestre algo razonable.
 *
 * Uso: `const { generarComandas } = await importConRecarga(() => import('../../lib/pdfExport'))`
 */
export async function importConRecarga<T>(factory: () => Promise<T>): Promise<T> {
  try {
    return await factory()
  } catch (err) {
    if (esErrorDeChunk(err)) {
      const recargo = recargarUnaVezPorChunk()
      if (recargo) throw new Error('Hay una versión nueva de la app. Recargando…')
      // Sólo llega acá tras agotar RELOAD_MAX_INTENTOS (recargarUnaVezPorChunk
      // ya recarga igual sin conexión, ver su comentario): recargar de nuevo
      // no va a arreglar nada.
      throw new Error('No se pudo cargar el módulo. Recargá la página e intentá de nuevo.')
    }
    throw err
  }
}

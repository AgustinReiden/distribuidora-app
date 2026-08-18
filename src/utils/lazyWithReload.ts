/**
 * lazyWithReload / importConRecarga — resiliencia ante chunks obsoletos tras un deploy.
 *
 * Problema: el SW de la PWA usa skipWaiting + clientsClaim, así que una versión
 * nueva toma control a mitad de sesión. La app vieja en memoria sigue pidiendo
 * chunks con el hash viejo (`Container-<hashViejo>.js` / `pdfExport-<hashViejo>.js`)
 * que ya no existen en el server → el import() dinámico falla con "Failed to fetch
 * dynamically imported module". En React.lazy el <Suspense> queda colgado; en un
 * handler (ej. descargar comanda) el catch solo muestra el error y no se puede usar.
 *
 * Solución: ante un fallo de carga de chunk, recargar UNA vez para traer el
 * index.html + chunks frescos. El guard por sessionStorage evita loops de
 * recarga (si tras recargar sigue fallando, propaga el error real).
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
 * NO recarga en dos casos, y los dos son el mismo usuario: el chofer en la calle.
 *
 * 1. Sin conexión. La app NO registra service worker (`injectRegister: false` en
 *    vite.config, y PWAPrompt quedó sin montar), así que no hay app shell
 *    precacheado: recargar sin red deja la pantalla en blanco y el chofer sin
 *    app en medio del reparto. Con red, recargar es lo correcto — el chunk viejo
 *    no existe más en el server.
 * 2. Ya se recargó `RELOAD_MAX_INTENTOS` veces. El cooldown viejo era temporal,
 *    no un tope: pasados 15 s volvía a recargar, y si el chunk seguía sin estar
 *    la pestaña entraba en loop de recargas.
 */
function recargarUnaVezPorChunk(): boolean {
  if (typeof navigator !== 'undefined' && navigator.onLine === false) return false

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
      // Sin conexión NO hay que decirle "recargá": no hay service worker, así
      // que recargar deja la pantalla en blanco. Es el chofer en la calle.
      const sinRed = typeof navigator !== 'undefined' && navigator.onLine === false
      throw new Error(
        sinRed
          ? 'No hay conexión. Volvé a intentar cuando tengas señal — no recargues la app.'
          : 'No se pudo cargar el módulo. Recargá la página e intentá de nuevo.',
      )
    }
    throw err
  }
}

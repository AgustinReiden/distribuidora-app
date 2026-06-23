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

/**
 * Recarga la página UNA vez (con cooldown por sessionStorage) para traer
 * index.html + chunks frescos. Devuelve true si disparó la recarga; false si
 * está en cooldown (ya recargó hace poco y sigue fallando → no insistir).
 */
function recargarUnaVezPorChunk(): boolean {
  const last = Number(sessionStorage.getItem(RELOAD_KEY) || 0)
  if (Date.now() - last > RELOAD_COOLDOWN_MS) {
    sessionStorage.setItem(RELOAD_KEY, String(Date.now()))
    window.location.reload()
    return true
  }
  return false
}

export function lazyWithReload<T extends ComponentType<unknown>>(
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
      throw new Error(
        recargo
          ? 'Hay una versión nueva de la app. Recargando…'
          : 'No se pudo cargar el módulo. Recargá la página e intentá de nuevo.',
      )
    }
    throw err
  }
}

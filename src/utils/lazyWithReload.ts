/**
 * lazyWithReload — React.lazy resiliente a chunks obsoletos tras un deploy.
 *
 * Problema: el SW de la PWA usa skipWaiting + clientsClaim, así que una versión
 * nueva toma control a mitad de sesión. La app vieja en memoria sigue pidiendo
 * chunks con el hash viejo (`Container-<hashViejo>.js`) que ya no existen en el
 * server → el import() dinámico falla → el <Suspense> queda colgado para
 * siempre (síntoma: "se queda cargando y no pasa nada" al navegar a una
 * pantalla lazy).
 *
 * Solución: ante un fallo de carga de chunk, recargar UNA vez para traer el
 * index.html + chunks frescos. El guard por sessionStorage evita loops de
 * recarga (si tras recargar sigue fallando, propaga el error real).
 */
import { lazy, type ComponentType, type LazyExoticComponent } from 'react'

const RELOAD_KEY = 'chunk-reload-at'
const RELOAD_COOLDOWN_MS = 15000

function esErrorDeChunk(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err)
  return /Failed to fetch dynamically imported module|error loading dynamically imported module|Importing a module script failed|ChunkLoadError/i.test(msg)
}

export function lazyWithReload<T extends ComponentType<unknown>>(
  factory: () => Promise<{ default: T }>,
): LazyExoticComponent<T> {
  return lazy(async () => {
    try {
      return await factory()
    } catch (err) {
      if (esErrorDeChunk(err)) {
        const last = Number(sessionStorage.getItem(RELOAD_KEY) || 0)
        if (Date.now() - last > RELOAD_COOLDOWN_MS) {
          sessionStorage.setItem(RELOAD_KEY, String(Date.now()))
          window.location.reload()
          // Promesa que nunca resuelve: mantiene el fallback hasta que recarga.
          return new Promise<{ default: T }>(() => {})
        }
      }
      throw err
    }
  })
}

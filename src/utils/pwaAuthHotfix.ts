import { logger } from './logger'

const AUTH_RUNTIME_HOTFIX_VERSION = '2026-03-20-auth-refresh-v1'
const AUTH_RUNTIME_HOTFIX_KEY = 'auth-runtime-hotfix-version'
const AUTH_RUNTIME_HOTFIX_RELOAD_KEY = `auth-runtime-hotfix-reload:${AUTH_RUNTIME_HOTFIX_VERSION}`

async function unregisterServiceWorkers(): Promise<number> {
  if (!('serviceWorker' in navigator) || typeof navigator.serviceWorker.getRegistrations !== 'function') {
    return 0
  }

  const registrations = await navigator.serviceWorker.getRegistrations()
  if (registrations.length === 0) {
    return 0
  }

  const results = await Promise.all(registrations.map(async (registration) => {
    try {
      return await registration.unregister()
    } catch (error) {
      logger.warn('[pwa-hotfix] Failed to unregister service worker', error)
      return false
    }
  }))

  return results.filter(Boolean).length
}

async function clearOriginCaches(): Promise<number> {
  if (!('caches' in window)) {
    return 0
  }

  const cacheNames = await window.caches.keys()
  if (cacheNames.length === 0) {
    return 0
  }

  const deleted = await Promise.all(cacheNames.map(async (cacheName) => {
    try {
      return await window.caches.delete(cacheName)
    } catch (error) {
      logger.warn(`[pwa-hotfix] Failed to delete cache ${cacheName}`, error)
      return false
    }
  }))

  return deleted.filter(Boolean).length
}

export async function applyAuthRuntimeHotfix(): Promise<boolean> {
  if (typeof window === 'undefined') {
    return false
  }

  if (localStorage.getItem(AUTH_RUNTIME_HOTFIX_KEY) === AUTH_RUNTIME_HOTFIX_VERSION) {
    return false
  }

  const [unregisteredCount, deletedCacheCount] = await Promise.all([
    unregisterServiceWorkers(),
    clearOriginCaches()
  ])

  localStorage.setItem(AUTH_RUNTIME_HOTFIX_KEY, AUTH_RUNTIME_HOTFIX_VERSION)

  const shouldReload = (unregisteredCount > 0 || deletedCacheCount > 0) &&
    sessionStorage.getItem(AUTH_RUNTIME_HOTFIX_RELOAD_KEY) !== '1'

  if (!shouldReload) {
    return false
  }

  sessionStorage.setItem(AUTH_RUNTIME_HOTFIX_RELOAD_KEY, '1')
  logger.warn('[pwa-hotfix] Resetting service workers and caches after auth stability hotfix', {
    unregisteredCount,
    deletedCacheCount
  })
  window.location.replace(window.location.href)
  return true
}

export default applyAuthRuntimeHotfix

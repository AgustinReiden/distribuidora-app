import { logger } from './logger'

export const AUTH_RUNTIME_HOTFIX_VERSION = '2026-04-10-merge-deploy-v1'
const AUTH_RUNTIME_HOTFIX_KEY = 'auth-runtime-hotfix-version'
const AUTH_RUNTIME_HOTFIX_RELOAD_KEY = `auth-runtime-hotfix-reload:${AUTH_RUNTIME_HOTFIX_VERSION}`

function logRecoveryEvent(message: string, context: Record<string, unknown> = {}): void {
  logger.info(message, context)

  if (typeof console !== 'undefined' && typeof console.info === 'function') {
    console.info(message, {
      recoveryVersion: AUTH_RUNTIME_HOTFIX_VERSION,
      ...context
    })
  }
}

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

  logRecoveryEvent('[pwa-hotfix] Starting recovery bootstrap')

  if (localStorage.getItem(AUTH_RUNTIME_HOTFIX_KEY) === AUTH_RUNTIME_HOTFIX_VERSION) {
    logRecoveryEvent('[pwa-hotfix] Recovery hotfix already applied')
    return false
  }

  const [unregisteredCount, deletedCacheCount] = await Promise.all([
    unregisterServiceWorkers(),
    clearOriginCaches()
  ])

  localStorage.setItem(AUTH_RUNTIME_HOTFIX_KEY, AUTH_RUNTIME_HOTFIX_VERSION)

  const shouldReload = (unregisteredCount > 0 || deletedCacheCount > 0) &&
    sessionStorage.getItem(AUTH_RUNTIME_HOTFIX_RELOAD_KEY) !== '1'

  logRecoveryEvent('[pwa-hotfix] Recovery cleanup completed', {
    unregisteredCount,
    deletedCacheCount,
    shouldReload
  })

  if (!shouldReload) {
    return false
  }

  sessionStorage.setItem(AUTH_RUNTIME_HOTFIX_RELOAD_KEY, '1')
  logger.warn('[pwa-hotfix] Resetting service workers and caches after Brave recovery release', {
    unregisteredCount,
    deletedCacheCount
  })
  window.location.replace(window.location.href)
  return true
}

export default applyAuthRuntimeHotfix

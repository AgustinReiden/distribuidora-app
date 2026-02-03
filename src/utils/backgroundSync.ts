/**
 * Background Sync - Utilidades para sincronización en segundo plano
 *
 * Usa la Background Sync API cuando está disponible,
 * con fallback a sincronización manual cuando vuelve la conexión.
 */

import { logger } from './logger'

const SYNC_TAG_PEDIDOS = 'sync-pedidos'
const SYNC_TAG_MERMAS = 'sync-mermas'

interface SyncManager {
  register(tag: string): Promise<void>;
}

interface PeriodicSyncManager {
  register(tag: string, options?: { minInterval: number }): Promise<void>;
}

interface ServiceWorkerRegistrationWithSync extends ServiceWorkerRegistration {
  sync: SyncManager;
  periodicSync?: PeriodicSyncManager;
}

/**
 * Verifica si Background Sync está soportado
 */
export function isBackgroundSyncSupported(): boolean {
  return 'serviceWorker' in navigator && 'SyncManager' in window
}

/**
 * Registra una sincronización de pedidos en background
 */
export async function registerPedidosSync(): Promise<boolean> {
  if (!isBackgroundSyncSupported()) {
    logger.info('Background Sync no soportado, usando fallback')
    return false
  }

  try {
    const registration = await navigator.serviceWorker.ready as ServiceWorkerRegistrationWithSync
    await registration.sync.register(SYNC_TAG_PEDIDOS)
    logger.info('Background sync registrado para pedidos')
    return true
  } catch (error) {
    logger.error('Error registrando background sync:', error)
    return false
  }
}

/**
 * Registra una sincronización de mermas en background
 */
export async function registerMermasSync(): Promise<boolean> {
  if (!isBackgroundSyncSupported()) {
    return false
  }

  try {
    const registration = await navigator.serviceWorker.ready as ServiceWorkerRegistrationWithSync
    await registration.sync.register(SYNC_TAG_MERMAS)
    logger.info('Background sync registrado para mermas')
    return true
  } catch (error) {
    logger.error('Error registrando background sync:', error)
    return false
  }
}

/**
 * Registra sincronización periódica (si está soportada)
 * Nota: Solo funciona en Chrome con permisos especiales
 */
export async function registerPeriodicSync(tag = 'periodic-sync', minInterval = 60 * 60 * 1000): Promise<boolean> {
  if (!('periodicSync' in navigator.serviceWorker)) {
    return false
  }

  try {
    const registration = await navigator.serviceWorker.ready as ServiceWorkerRegistrationWithSync
    // @ts-expect-error - periodic-background-sync is a valid permission name in some browsers
    const status = await navigator.permissions.query({ name: 'periodic-background-sync' })

    if (status.state === 'granted' && registration.periodicSync) {
      await registration.periodicSync.register(tag, {
        minInterval
      })
      logger.info('Periodic sync registrado:', tag)
      return true
    }
  } catch (error) {
    logger.error('Error registrando periodic sync:', error)
  }
  return false
}

export interface SWMessage {
  type: string;
  payload?: unknown;
}

/**
 * Envía mensaje al Service Worker
 */
export async function sendMessageToSW<T = unknown>(message: SWMessage): Promise<T | null> {
  if (!navigator.serviceWorker.controller) {
    return null
  }

  return new Promise((resolve) => {
    const messageChannel = new MessageChannel()
    messageChannel.port1.onmessage = (event: MessageEvent) => {
      resolve(event.data as T)
    }
    navigator.serviceWorker.controller?.postMessage(message, [messageChannel.port2])
  })
}

/**
 * Notifica al SW que hay datos pendientes para sincronizar
 */
export async function notifyPendingData<T = unknown>(type: string, count: number): Promise<T | null> {
  return sendMessageToSW<T>({
    type: 'PENDING_DATA',
    payload: { dataType: type, count }
  })
}

/**
 * Escucha mensajes del Service Worker
 */
export function onSWMessage(callback: (data: unknown) => void): void {
  navigator.serviceWorker.addEventListener('message', (event: MessageEvent) => {
    callback(event.data)
  })
}

/**
 * Verifica el estado de la conexión con retry
 */
export async function checkConnection(url = '/api/health', retries = 3): Promise<boolean> {
  for (let i = 0; i < retries; i++) {
    try {
      const response = await fetch(url, {
        method: 'HEAD',
        cache: 'no-store',
        signal: AbortSignal.timeout(5000)
      })
      return response.ok
    } catch {
      if (i === retries - 1) return false
      await new Promise(r => setTimeout(r, 1000 * (i + 1)))
    }
  }
  return false
}

export type ConnectionCallback = () => void;

/**
 * Hook para escuchar cambios de conexión con debounce
 */
export function createConnectionListener(
  onOnline?: ConnectionCallback,
  onOffline?: ConnectionCallback,
  debounceMs = 1000
): () => void {
  let timeoutId: ReturnType<typeof setTimeout> | null = null
  let lastState = navigator.onLine

  const handler = (): void => {
    if (timeoutId) clearTimeout(timeoutId)

    timeoutId = setTimeout(() => {
      const currentState = navigator.onLine
      if (currentState !== lastState) {
        lastState = currentState
        if (currentState) {
          onOnline?.()
        } else {
          onOffline?.()
        }
      }
    }, debounceMs)
  }

  window.addEventListener('online', handler)
  window.addEventListener('offline', handler)

  return () => {
    window.removeEventListener('online', handler)
    window.removeEventListener('offline', handler)
    if (timeoutId) clearTimeout(timeoutId)
  }
}

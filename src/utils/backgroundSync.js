/**
 * Background Sync - Utilidades para sincronización en segundo plano
 *
 * Usa la Background Sync API cuando está disponible,
 * con fallback a sincronización manual cuando vuelve la conexión.
 */

const SYNC_TAG_PEDIDOS = 'sync-pedidos'
const SYNC_TAG_MERMAS = 'sync-mermas'

/**
 * Verifica si Background Sync está soportado
 */
export function isBackgroundSyncSupported() {
  return 'serviceWorker' in navigator && 'SyncManager' in window
}

/**
 * Registra una sincronización de pedidos en background
 */
export async function registerPedidosSync() {
  if (!isBackgroundSyncSupported()) {
    console.log('Background Sync no soportado, usando fallback')
    return false
  }

  try {
    const registration = await navigator.serviceWorker.ready
    await registration.sync.register(SYNC_TAG_PEDIDOS)
    console.log('Background sync registrado para pedidos')
    return true
  } catch (error) {
    console.error('Error registrando background sync:', error)
    return false
  }
}

/**
 * Registra una sincronización de mermas en background
 */
export async function registerMermasSync() {
  if (!isBackgroundSyncSupported()) {
    return false
  }

  try {
    const registration = await navigator.serviceWorker.ready
    await registration.sync.register(SYNC_TAG_MERMAS)
    console.log('Background sync registrado para mermas')
    return true
  } catch (error) {
    console.error('Error registrando background sync:', error)
    return false
  }
}

/**
 * Registra sincronización periódica (si está soportada)
 * Nota: Solo funciona en Chrome con permisos especiales
 */
export async function registerPeriodicSync(tag = 'periodic-sync', minInterval = 60 * 60 * 1000) {
  if (!('periodicSync' in navigator.serviceWorker)) {
    return false
  }

  try {
    const registration = await navigator.serviceWorker.ready
    const status = await navigator.permissions.query({
      name: 'periodic-background-sync'
    })

    if (status.state === 'granted') {
      await registration.periodicSync.register(tag, {
        minInterval
      })
      console.log('Periodic sync registrado:', tag)
      return true
    }
  } catch (error) {
    console.error('Error registrando periodic sync:', error)
  }
  return false
}

/**
 * Envía mensaje al Service Worker
 */
export async function sendMessageToSW(message) {
  if (!navigator.serviceWorker.controller) {
    return null
  }

  return new Promise((resolve) => {
    const messageChannel = new MessageChannel()
    messageChannel.port1.onmessage = (event) => {
      resolve(event.data)
    }
    navigator.serviceWorker.controller.postMessage(message, [messageChannel.port2])
  })
}

/**
 * Notifica al SW que hay datos pendientes para sincronizar
 */
export async function notifyPendingData(type, count) {
  return sendMessageToSW({
    type: 'PENDING_DATA',
    payload: { dataType: type, count }
  })
}

/**
 * Escucha mensajes del Service Worker
 */
export function onSWMessage(callback) {
  navigator.serviceWorker.addEventListener('message', (event) => {
    callback(event.data)
  })
}

/**
 * Verifica el estado de la conexión con retry
 */
export async function checkConnection(url = '/api/health', retries = 3) {
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

/**
 * Hook para escuchar cambios de conexión con debounce
 */
export function createConnectionListener(onOnline, onOffline, debounceMs = 1000) {
  let timeoutId = null
  let lastState = navigator.onLine

  const handler = () => {
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

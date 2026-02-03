/**
 * Base de datos offline con IndexedDB (Dexie.js)
 *
 * Proporciona almacenamiento persistente para:
 * - Cola de operaciones pendientes (sincronización)
 * - Cache de datos para modo offline
 * - Rutas optimizadas guardadas
 *
 * Ventajas sobre localStorage:
 * - Sin límite de 5MB (puede almacenar GB)
 * - Transaccional (ACID)
 * - Soporta índices para búsquedas rápidas
 * - No bloquea el hilo principal
 */

import Dexie, { type Table } from 'dexie'

// =============================================================================
// TIPOS
// =============================================================================

/**
 * Estado de una operación en la cola
 */
export type OperationStatus = 'pending' | 'processing' | 'failed' | 'completed'

/**
 * Tipo de operación
 */
export type OperationType =
  | 'CREATE_PEDIDO'
  | 'UPDATE_PEDIDO'
  | 'DELETE_PEDIDO'
  | 'CREATE_CLIENTE'
  | 'UPDATE_CLIENTE'
  | 'CREATE_MERMA'
  | 'UPDATE_PRODUCTO'
  | 'SYNC_PAGO'

/**
 * Operación pendiente en la cola
 */
export interface PendingOperation {
  id?: number // Auto-increment
  type: OperationType
  payload: Record<string, unknown>
  status: OperationStatus
  retryCount: number
  maxRetries: number
  lastError?: string
  hash: string // Para detectar duplicados
  createdAt: Date
  updatedAt: Date
  userId?: string
}

/**
 * Cache de datos offline
 */
export interface OfflineCache {
  id?: number
  key: string // Ej: 'productos', 'clientes', 'pedidos'
  data: unknown
  version: number
  updatedAt: Date
  expiresAt?: Date
}

/**
 * Ruta optimizada guardada
 */
export interface SavedRoute {
  id?: number
  nombre: string
  descripcion?: string
  transportistaId: string
  clienteIds: string[]
  ordenOptimizado: number[] // Índices del orden optimizado
  polylineEncoded?: string // Para dibujar sin llamar a Google
  distanciaTotal?: number // metros
  duracionEstimada?: number // segundos
  createdAt: Date
  updatedAt: Date
  lastUsedAt?: Date
}

/**
 * Evento de sincronización para logging
 */
export interface SyncEvent {
  id?: number
  operationId?: number
  type: 'sync_started' | 'sync_completed' | 'sync_failed' | 'operation_retried'
  details?: string
  createdAt: Date
}

// =============================================================================
// CLASE: Base de datos Dexie
// =============================================================================

class DistribuidoraDB extends Dexie {
  pendingOperations!: Table<PendingOperation, number>
  offlineCache!: Table<OfflineCache, number>
  savedRoutes!: Table<SavedRoute, number>
  syncEvents!: Table<SyncEvent, number>

  constructor() {
    super('DistribuidoraOfflineDB')

    // Esquema de la base de datos
    this.version(1).stores({
      // Cola de operaciones pendientes
      pendingOperations: '++id, type, status, hash, createdAt, userId',

      // Cache de datos offline
      offlineCache: '++id, key, updatedAt, expiresAt',

      // Rutas guardadas
      savedRoutes: '++id, nombre, transportistaId, updatedAt, lastUsedAt',

      // Eventos de sincronización
      syncEvents: '++id, operationId, type, createdAt'
    })
  }
}

// Instancia singleton
export const db = new DistribuidoraDB()

// =============================================================================
// FUNCIONES: Cola de operaciones
// =============================================================================

/**
 * Genera un hash único para detectar operaciones duplicadas
 */
function generateOperationHash(type: OperationType, payload: Record<string, unknown>): string {
  const str = JSON.stringify({ type, payload })
  let hash = 0
  for (let i = 0; i < str.length; i++) {
    const char = str.charCodeAt(i)
    hash = ((hash << 5) - hash) + char
    hash = hash & hash // Convert to 32bit integer
  }
  return `${type}-${hash.toString(16)}-${Date.now()}`
}

/**
 * Agregar operación a la cola
 * Retorna el ID de la operación o null si ya existe (duplicado)
 */
export async function queueOperation(
  type: OperationType,
  payload: Record<string, unknown>,
  userId?: string,
  maxRetries = 5
): Promise<number | null> {
  const hash = generateOperationHash(type, payload)

  // Verificar si ya existe una operación idéntica pendiente
  const existing = await db.pendingOperations
    .where('hash')
    .equals(hash)
    .and(op => op.status === 'pending' || op.status === 'processing')
    .first()

  if (existing) {
    console.warn('[OfflineQueue] Operación duplicada detectada, ignorando:', type)
    return null
  }

  const now = new Date()
  const id = await db.pendingOperations.add({
    type,
    payload,
    status: 'pending',
    retryCount: 0,
    maxRetries,
    hash,
    createdAt: now,
    updatedAt: now,
    userId
  })

  // Registrar evento
  await db.syncEvents.add({
    operationId: id,
    type: 'sync_started',
    details: `Operación ${type} encolada`,
    createdAt: now
  })

  return id
}

/**
 * Obtener operaciones pendientes ordenadas por prioridad (FIFO)
 */
export async function getPendingOperations(limit = 10): Promise<PendingOperation[]> {
  return db.pendingOperations
    .where('status')
    .anyOf(['pending', 'failed'])
    .and(op => op.retryCount < op.maxRetries)
    .sortBy('createdAt')
    .then(ops => ops.slice(0, limit))
}

/**
 * Marcar operación como procesando
 */
export async function markAsProcessing(id: number): Promise<void> {
  await db.pendingOperations.update(id, {
    status: 'processing',
    updatedAt: new Date()
  })
}

/**
 * Marcar operación como completada
 */
export async function markAsCompleted(id: number): Promise<void> {
  const now = new Date()
  await db.pendingOperations.update(id, {
    status: 'completed',
    updatedAt: now
  })

  await db.syncEvents.add({
    operationId: id,
    type: 'sync_completed',
    createdAt: now
  })
}

/**
 * Marcar operación como fallida (incrementa retry)
 */
export async function markAsFailed(id: number, error: string): Promise<void> {
  const operation = await db.pendingOperations.get(id)
  if (!operation) return

  const newRetryCount = operation.retryCount + 1
  const now = new Date()

  await db.pendingOperations.update(id, {
    status: newRetryCount >= operation.maxRetries ? 'failed' : 'pending',
    retryCount: newRetryCount,
    lastError: error,
    updatedAt: now
  })

  await db.syncEvents.add({
    operationId: id,
    type: newRetryCount >= operation.maxRetries ? 'sync_failed' : 'operation_retried',
    details: `Intento ${newRetryCount}/${operation.maxRetries}: ${error}`,
    createdAt: now
  })
}

/**
 * Obtener conteo de operaciones por estado
 */
export async function getOperationCounts(): Promise<{
  pending: number
  processing: number
  failed: number
  completed: number
}> {
  const [pending, processing, failed, completed] = await Promise.all([
    db.pendingOperations.where('status').equals('pending').count(),
    db.pendingOperations.where('status').equals('processing').count(),
    db.pendingOperations.where('status').equals('failed').count(),
    db.pendingOperations.where('status').equals('completed').count()
  ])

  return { pending, processing, failed, completed }
}

/**
 * Limpiar operaciones completadas antiguas (más de 7 días)
 */
export async function cleanupOldOperations(daysOld = 7): Promise<number> {
  const cutoff = new Date()
  cutoff.setDate(cutoff.getDate() - daysOld)

  const toDelete = await db.pendingOperations
    .where('status')
    .equals('completed')
    .and(op => op.updatedAt < cutoff)
    .primaryKeys()

  await db.pendingOperations.bulkDelete(toDelete)
  return toDelete.length
}

// =============================================================================
// FUNCIONES: Cache offline
// =============================================================================

/**
 * Guardar datos en cache
 */
export async function cacheData(
  key: string,
  data: unknown,
  expiresInMinutes?: number
): Promise<void> {
  const now = new Date()
  const expiresAt = expiresInMinutes
    ? new Date(now.getTime() + expiresInMinutes * 60 * 1000)
    : undefined

  // Buscar si ya existe
  const existing = await db.offlineCache.where('key').equals(key).first()

  if (existing) {
    await db.offlineCache.update(existing.id!, {
      data,
      version: existing.version + 1,
      updatedAt: now,
      expiresAt
    })
  } else {
    await db.offlineCache.add({
      key,
      data,
      version: 1,
      updatedAt: now,
      expiresAt
    })
  }
}

/**
 * Obtener datos del cache
 */
export async function getCachedData<T>(key: string): Promise<T | null> {
  const cached = await db.offlineCache.where('key').equals(key).first()

  if (!cached) return null

  // Verificar expiración
  if (cached.expiresAt && cached.expiresAt < new Date()) {
    await db.offlineCache.delete(cached.id!)
    return null
  }

  return cached.data as T
}

/**
 * Invalidar cache
 */
export async function invalidateCache(key: string): Promise<void> {
  await db.offlineCache.where('key').equals(key).delete()
}

/**
 * Limpiar todo el cache expirado
 */
export async function cleanupExpiredCache(): Promise<number> {
  const now = new Date()
  const expired = await db.offlineCache
    .where('expiresAt')
    .below(now)
    .primaryKeys()

  await db.offlineCache.bulkDelete(expired)
  return expired.length
}

// =============================================================================
// FUNCIONES: Rutas guardadas
// =============================================================================

/**
 * Guardar ruta optimizada
 */
export async function saveOptimizedRoute(route: Omit<SavedRoute, 'id' | 'createdAt' | 'updatedAt'>): Promise<number> {
  const now = new Date()
  return db.savedRoutes.add({
    ...route,
    createdAt: now,
    updatedAt: now
  })
}

/**
 * Obtener rutas guardadas de un transportista
 */
export async function getSavedRoutes(transportistaId: string): Promise<SavedRoute[]> {
  return db.savedRoutes
    .where('transportistaId')
    .equals(transportistaId)
    .reverse()
    .sortBy('lastUsedAt')
}

/**
 * Buscar ruta por clientes (para reutilización)
 */
export async function findMatchingRoute(
  transportistaId: string,
  clienteIds: string[],
  tolerancePercent = 20
): Promise<SavedRoute | null> {
  const routes = await getSavedRoutes(transportistaId)

  for (const route of routes) {
    // Calcular similitud
    const routeSet = new Set(route.clienteIds)
    const inputSet = new Set(clienteIds)

    const intersection = new Set([...routeSet].filter(x => inputSet.has(x)))
    const union = new Set([...routeSet, ...inputSet])

    const similarity = (intersection.size / union.size) * 100

    // Si la similitud es mayor al umbral, usar esta ruta
    if (similarity >= (100 - tolerancePercent)) {
      return route
    }
  }

  return null
}

/**
 * Actualizar última vez usada
 */
export async function markRouteAsUsed(routeId: number): Promise<void> {
  await db.savedRoutes.update(routeId, {
    lastUsedAt: new Date(),
    updatedAt: new Date()
  })
}

/**
 * Actualizar ruta existente
 */
export async function updateSavedRoute(
  routeId: number,
  updates: Partial<Omit<SavedRoute, 'id' | 'createdAt'>>
): Promise<void> {
  await db.savedRoutes.update(routeId, {
    ...updates,
    updatedAt: new Date()
  })
}

/**
 * Eliminar ruta
 */
export async function deleteSavedRoute(routeId: number): Promise<void> {
  await db.savedRoutes.delete(routeId)
}

// =============================================================================
// FUNCIONES: Utilidades
// =============================================================================

/**
 * Verificar si la base de datos está disponible
 */
export async function isDbAvailable(): Promise<boolean> {
  try {
    await db.open()
    return true
  } catch {
    return false
  }
}

/**
 * Obtener estadísticas de la base de datos
 */
export async function getDbStats(): Promise<{
  pendingOperations: number
  cacheEntries: number
  savedRoutes: number
  syncEvents: number
  estimatedSizeMB: number
}> {
  const [pendingOperations, cacheEntries, savedRoutes, syncEvents] = await Promise.all([
    db.pendingOperations.count(),
    db.offlineCache.count(),
    db.savedRoutes.count(),
    db.syncEvents.count()
  ])

  // Estimación muy básica del tamaño
  const estimatedSizeMB = (pendingOperations * 2 + cacheEntries * 10 + savedRoutes * 5) / 1024

  return {
    pendingOperations,
    cacheEntries,
    savedRoutes,
    syncEvents,
    estimatedSizeMB
  }
}

/**
 * Limpiar toda la base de datos (usar con cuidado)
 */
export async function clearAllData(): Promise<void> {
  await db.transaction('rw', [db.pendingOperations, db.offlineCache, db.savedRoutes, db.syncEvents], async () => {
    await db.pendingOperations.clear()
    await db.offlineCache.clear()
    await db.savedRoutes.clear()
    await db.syncEvents.clear()
  })
}

export default db

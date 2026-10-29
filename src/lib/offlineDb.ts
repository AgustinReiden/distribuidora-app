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
import { quitarRegalosDelPayload } from '../utils/pedidoSinRegalos'
import { quitarCombosDelPayload } from '../utils/pedidoSinCombos'

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
  sucursalId?: number // Multi-tenant: sucursal que originó la operación
  /**
   * #1153: el server la rechazó porque un regalo dejó de ser legal
   * (`regalo_fuera_de_promo`) y el pedido tiene regalos para quitar. El banner
   * ofrece "Sincronizar sin el regalo". No está indexada: no cambia el esquema.
   */
  rechazoRegalo?: boolean
  /**
   * #1191: el server la rechazó por un combo (`combo_fuera_de_regla`) y el
   * pedido tiene combos para sacar. El banner ofrece "Sincronizar sin los
   * combos". No está indexada.
   */
  rechazoCombo?: boolean
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
  type: 'sync_started' | 'sync_completed' | 'sync_failed' | 'operation_retried' | 'operation_discarded'
  details?: string
  createdAt: Date
  /**
   * #1264: rastro de una operación borrada a mano desde el banner (sólo en
   * `operation_discarded`). La operación entera, payload incluido, para poder
   * reconstruir el pedido si se borró por error. No están indexados: no
   * cambian el esquema.
   */
  operacion?: PendingOperation
  /** Quién la borró (el usuario activo, que puede no ser el dueño). */
  descartadaPor?: string
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
  // performance.now() aporta sub-ms para que dos llamadas dentro del mismo
  // milisegundo no colisionen (flake de CI). Date.now() queda para orden.
  const tick = typeof performance !== 'undefined' && typeof performance.now === 'function'
    ? performance.now().toString().replace('.', '')
    : String(Math.random()).slice(2)
  return `${type}-${hash.toString(16)}-${Date.now()}-${tick}`
}

/**
 * Genera una clave de cache con namespace de sucursal.
 * Permite aislar el cache por sucursal en modo offline.
 */
export function scopedCacheKey(key: string, sucursalId?: number | null): string {
  return sucursalId != null ? `s${sucursalId}:${key}` : key
}

/** El pedido de almacenamiento persistente de esta carga de la página. */
let persistenciaPedida: Promise<boolean> | null = null

/**
 * Agregar operación a la cola. Retorna el ID de la operación.
 *
 * `hash` se guarda por si a futuro hace falta deduplicar por contenido (D-7 la
 * dejó afuera por ahora), pero HOY nada la consulta: el hash lleva
 * `Date.now()`/`performance.now()`, así que dos llamadas nunca chocan a
 * propósito. No hay chequeo de duplicados acá.
 */
export async function queueOperation(
  type: OperationType,
  payload: Record<string, unknown>,
  userId?: string,
  maxRetries = 5,
  sucursalId?: number
): Promise<number> {
  const hash = generateOperationHash(type, payload)
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
    userId,
    sucursalId
  })

  // Lo que se acaba de encolar es, a veces, un pedido tomado sin señal: el
  // primer encolado de la sesión es el momento de pedir que el navegador no
  // borre la cola bajo presión de espacio (#1264). No se espera.
  persistenciaPedida ??= pedirAlmacenamientoPersistente()

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
 * ¿Esta operación es del usuario y la sucursal que están activos ahora?
 *
 * IndexedDB es del dispositivo, no de la sesión: el logout no la toca (a
 * propósito — una cola borrada es un pedido perdido). En un teléfono
 * compartido, sin este filtro el usuario B veía los pedidos de A, los
 * replayaba, el guard de la mig 219 los rechazaba con 42501 y terminaban en
 * `failed` sin que A se enterara.
 *
 * Las operaciones **sin dueño anotado** pasan el filtro: son las que se
 * encolaron antes de que la cola registrara `userId` (y las mermas, que hasta
 * ahora no lo llevaban). Esconderlas las dejaría huérfanas para siempre en vez
 * de protegerlas; que se vean es lo que permite sincronizarlas o descartarlas.
 * Mismo criterio con `sucursalId`: el replay ya las marca `failed` con un
 * motivo explícito (ver sincronizarPedidos), y para eso tiene que poder verlas.
 */
function esDelUsuarioActivo(
  op: PendingOperation,
  userId?: string | null,
  sucursalId?: number | null
): boolean {
  if (userId && op.userId != null && op.userId !== userId) return false
  if (sucursalId != null && op.sucursalId != null && op.sucursalId !== sucursalId) return false
  return true
}

/**
 * Obtener operaciones pendientes ordenadas por prioridad (FIFO)
 *
 * `userId`/`sucursalId` acotan la cola a la sesión activa (ver
 * `esDelUsuarioActivo`). Se filtran en memoria y no por índice a propósito: el
 * índice de `status` ya recorta a lo pendiente, que son unidades o decenas de
 * filas, y un índice compuesto obligaría a versionar el esquema de Dexie en
 * todos los teléfonos instalados para no ganar nada medible.
 */
export async function getPendingOperations(
  limit = 10,
  userId?: string | null,
  sucursalId?: number | null
): Promise<PendingOperation[]> {
  return db.pendingOperations
    .where('status')
    .anyOf(['pending', 'failed'])
    .and(op => op.retryCount < op.maxRetries)
    .and(op => esDelUsuarioActivo(op, userId, sucursalId))
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
 *
 * `terminal: true` la deja en `failed` en el acto, sin gastar los reintentos
 * que quedan: es para los fallos que reintentar no puede arreglar (la clave de
 * idempotencia ya la tiene otro pedido, por ejemplo). Queda visible en el panel
 * de fallidas, que es donde alguien puede decidir qué hacer con ella.
 *
 * Una operación `completed` no se toca (#1264). Con dos pestañas, las dos leen
 * la misma operación pendiente: la A la sincroniza y la B, que falló después
 * (red, un 5xx), la devolvía a la cola encima del `completed` — un pedido que
 * ya estaba en el servidor quedaba otra vez pendiente o fallido, listo para
 * que alguien lo recargara a mano. La lectura y la escritura van en la misma
 * transacción para que la A no se meta en el medio.
 */
export async function markAsFailed(
  id: number,
  error: string,
  options: { terminal?: boolean; rechazoRegalo?: boolean; rechazoCombo?: boolean } = {}
): Promise<void> {
  await db.transaction('rw', [db.pendingOperations, db.syncEvents], async () => {
    const operation = await db.pendingOperations.get(id)
    if (!operation || operation.status === 'completed') return

    const newRetryCount = options.terminal ? operation.maxRetries : operation.retryCount + 1
    const agotada = newRetryCount >= operation.maxRetries
    const now = new Date()

    await db.pendingOperations.update(id, {
      status: agotada ? 'failed' : 'pending',
      retryCount: newRetryCount,
      lastError: error,
      // Cada fallo dice el suyo: undefined borra la marca de uno anterior.
      rechazoRegalo: options.rechazoRegalo ? true : undefined,
      rechazoCombo: options.rechazoCombo ? true : undefined,
      updatedAt: now
    })

    await db.syncEvents.add({
      operationId: id,
      type: agotada ? 'sync_failed' : 'operation_retried',
      details: `Intento ${newRetryCount}/${operation.maxRetries}: ${error}`,
      createdAt: now
    })
  })
}

/**
 * Anotar un fallo SIN respuesta del servidor (sin señal, "Failed to fetch",
 * timeout del fetch): no gasta reintentos (#1264, decisión del dueño).
 *
 * Con `markAsFailed`, cada auto-sync (ventana de 30 s) gastaba uno: con una
 * señal que "está" pero no pasa datos, a los ~2,5 minutos el pedido quedaba
 * `failed`, salía del contador de pendientes y sólo quedaba el banner rojo.
 * Acá sigue `pending` con el motivo a la vista, y se reintenta sin límite
 * mientras haya conexión. Es seguro porque `crear_pedido_idempotente` no
 * duplica. Sólo gastan reintentos las respuestas del servidor (un 5xx, un
 * rechazo), que siguen por `markAsFailed`.
 *
 * Igual que `markAsFailed`, no toca una operación `completed`.
 */
export async function anotarFalloDeRed(id: number, error: string): Promise<void> {
  await db.transaction('rw', [db.pendingOperations, db.syncEvents], async () => {
    const operation = await db.pendingOperations.get(id)
    if (!operation || operation.status === 'completed') return

    const now = new Date()
    await db.pendingOperations.update(id, {
      status: 'pending',
      lastError: error,
      updatedAt: now
    })

    await db.syncEvents.add({
      operationId: id,
      type: 'operation_retried',
      details: `Sin respuesta del servidor, no gasta reintento (${operation.retryCount}/${operation.maxRetries}): ${error}`,
      createdAt: now
    })
  })
}

/**
 * Obtener conteo de operaciones por estado.
 *
 * Con `userId`/`sucursalId` cuenta sólo lo de la sesión activa (ver
 * `esDelUsuarioActivo`); sin ellos, todo el dispositivo.
 */
export async function getOperationCounts(
  userId?: string | null,
  sucursalId?: number | null
): Promise<{
  pending: number
  processing: number
  failed: number
  completed: number
}> {
  const contar = (status: OperationStatus) => db.pendingOperations
    .where('status')
    .equals(status)
    .and(op => esDelUsuarioActivo(op, userId, sucursalId))
    .count()

  const [pending, processing, failed, completed] = await Promise.all([
    contar('pending'),
    contar('processing'),
    contar('failed'),
    contar('completed')
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

const DIA_MS = 24 * 60 * 60 * 1000
/** Lo que vive un evento de sincronización: es un log de depuración. */
const DIAS_EVENTOS_SYNC = 7
/** Lo que vive el rastro de una operación borrada a mano (ver `discardFailedOperations`). */
const DIAS_RASTRO_DESCARTE = 90
/**
 * Tope de eventos recientes. La ventana de días sola no alcanza: una caja que
 * vende cientos de veces por día deja dos eventos por venta.
 */
const MAX_EVENTOS_SYNC = 1000

/**
 * Poda `syncEvents` (#1264): crecía una fila por encolado, éxito o fallo, y
 * nadie la leía ni la borraba. Quedan los eventos de los últimos 7 días, hasta
 * 1000. El rastro de lo borrado a mano no cuenta para el tope y dura 90 días.
 */
export async function cleanupOldSyncEvents(): Promise<number> {
  const ahora = Date.now()
  const corteEventos = new Date(ahora - DIAS_EVENTOS_SYNC * DIA_MS)
  const corteRastro = new Date(ahora - DIAS_RASTRO_DESCARTE * DIA_MS)

  return db.transaction('rw', db.syncEvents, async () => {
    const viejos = await db.syncEvents
      .where('createdAt')
      .below(corteEventos)
      .filter(e => e.type !== 'operation_discarded' || e.createdAt < corteRastro)
      .primaryKeys()
    await db.syncEvents.bulkDelete(viejos)

    const recientes = await db.syncEvents
      .orderBy('createdAt')
      .reverse()
      .filter(e => e.type !== 'operation_discarded')
      .primaryKeys()
    const sobrantes = recientes.slice(MAX_EVENTOS_SYNC)
    await db.syncEvents.bulkDelete(sobrantes)

    return viejos.length + sobrantes.length
  })
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
  expiresInMinutes?: number,
  sucursalId?: number | null
): Promise<void> {
  const effectiveKey = scopedCacheKey(key, sucursalId)
  const now = new Date()
  const expiresAt = expiresInMinutes
    ? new Date(now.getTime() + expiresInMinutes * 60 * 1000)
    : undefined

  // Buscar si ya existe
  const existing = await db.offlineCache.where('key').equals(effectiveKey).first()

  if (existing) {
    await db.offlineCache.update(existing.id!, {
      data,
      version: existing.version + 1,
      updatedAt: now,
      expiresAt
    })
  } else {
    await db.offlineCache.add({
      key: effectiveKey,
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
export async function getCachedData<T>(key: string, sucursalId?: number | null): Promise<T | null> {
  const effectiveKey = scopedCacheKey(key, sucursalId)
  const cached = await db.offlineCache.where('key').equals(effectiveKey).first()

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
export async function invalidateCache(key: string, sucursalId?: number | null): Promise<void> {
  const effectiveKey = scopedCacheKey(key, sucursalId)
  await db.offlineCache.where('key').equals(effectiveKey).delete()
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
 * Pide almacenamiento persistente (#1264). Sin esto el navegador puede borrar
 * IndexedDB bajo presión de espacio, y con ella la cola: un pedido tomado sin
 * señal se pierde sin que nadie se entere. Chrome lo concede o lo niega sin
 * preguntar; Firefox le pregunta una vez a la persona. Devuelve si quedó
 * persistente; sin la API, o si falla, false y nada más.
 */
export async function pedirAlmacenamientoPersistente(): Promise<boolean> {
  try {
    const storage = typeof navigator !== 'undefined' ? navigator.storage : undefined
    if (!storage?.persist) return false
    if (await storage.persisted?.()) return true
    return await storage.persist()
  } catch {
    return false
  }
}

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

/**
 * Limpia los caches de LECTURA (datos de productos/clientes cacheados y
 * rutas guardadas). Para logout: a diferencia de `clearAllData`, NO toca
 * `pendingOperations` -- la cola offline sobrevive al logout (decisión FE-1)
 * y se oculta por usuario en la UI, no se descarta acá -- ni `syncEvents`,
 * que guarda el rastro de lo borrado a mano (#1264) y se poda solo
 * (`cleanupOldSyncEvents`).
 */
export async function limpiarCachesDeLectura(): Promise<void> {
  await db.transaction('rw', [db.offlineCache, db.savedRoutes], async () => {
    await db.offlineCache.clear()
    await db.savedRoutes.clear()
  })
}

/**
 * Obtener operaciones fallidas.
 *
 * `userId`/`sucursalId` acotan a la sesión activa, como `getPendingOperations`
 * (#1264): en un teléfono compartido, el banner le mostraba a B el `lastError`
 * de A, que puede nombrar clientes. El límite va después del filtro.
 */
export async function getFailedOperations(
  limit = 50,
  userId?: string | null,
  sucursalId?: number | null
): Promise<PendingOperation[]> {
  return db.pendingOperations
    .where('status')
    .equals('failed')
    .and(op => esDelUsuarioActivo(op, userId, sucursalId))
    .limit(limit)
    .toArray()
}

/**
 * Reintentar una operación fallida (resetea el contador de reintentos)
 */
export async function retryFailedOperation(id: number): Promise<void> {
  const operation = await db.pendingOperations.get(id)
  if (!operation || operation.status !== 'failed') {
    throw new Error('Operación no encontrada o no está en estado fallido')
  }

  const now = new Date()
  await db.pendingOperations.update(id, {
    status: 'pending',
    retryCount: 0,
    lastError: undefined,
    rechazoRegalo: undefined,
    rechazoCombo: undefined,
    updatedAt: now
  })

  await db.syncEvents.add({
    operationId: id,
    type: 'operation_retried',
    details: 'Operación marcada para reintento manual',
    createdAt: now
  })
}

/**
 * "Sincronizar sin el regalo" (#1153): la operación rechazada por un regalo
 * que dejó de ser legal vuelve a la cola sin sus líneas de regalo.
 *
 * Mismo `offlineUuid`, así que la misma clave de idempotencia: el rechazo no
 * la selló (`crear_pedido_idempotente` sólo sella con success), y si el
 * reintento se corta después del COMMIT, el siguiente encuentra el pedido.
 * Sólo para una operación `failed` con la marca: lo decide el preventista.
 */
export async function reintentarSinRegalos(id: number): Promise<void> {
  await db.transaction('rw', [db.pendingOperations, db.syncEvents], async () => {
    const operation = await db.pendingOperations.get(id)
    if (!operation || operation.status !== 'failed' || !operation.rechazoRegalo) {
      throw new Error('La operación no está rechazada por un regalo')
    }
    const payload = quitarRegalosDelPayload(operation.payload)
    if (!payload) {
      throw new Error('El pedido no tiene regalos para quitar')
    }
    const now = new Date()
    await db.pendingOperations.update(id, {
      payload,
      status: 'pending',
      retryCount: 0,
      lastError: undefined,
      rechazoRegalo: undefined,
      updatedAt: now
    })
    await db.syncEvents.add({
      operationId: id,
      type: 'operation_retried',
      details: 'Reintento sin el regalo',
      createdAt: now
    })
  })
}

/**
 * "Sincronizar sin los combos" (#1191): la operación rechazada por un combo
 * vuelve a la cola con sus líneas de combo a precio sin combo. Misma clave de
 * idempotencia, como `reintentarSinRegalos`. Lo decide el preventista.
 */
export async function reintentarSinCombos(id: number): Promise<void> {
  await db.transaction('rw', [db.pendingOperations, db.syncEvents], async () => {
    const operation = await db.pendingOperations.get(id)
    if (!operation || operation.status !== 'failed' || !operation.rechazoCombo) {
      throw new Error('La operación no está rechazada por un combo')
    }
    const payload = quitarCombosDelPayload(operation.payload)
    if (!payload) {
      throw new Error('El pedido no tiene combos para sacar')
    }
    const now = new Date()
    await db.pendingOperations.update(id, {
      payload,
      status: 'pending',
      retryCount: 0,
      lastError: undefined,
      rechazoCombo: undefined,
      updatedAt: now
    })
    await db.syncEvents.add({
      operationId: id,
      type: 'operation_retried',
      details: 'Reintento sin los combos',
      createdAt: now
    })
  })
}

/**
 * Las fallidas de la sesión activa, leídas dentro de una transacción. Sin
 * límite: "Reintentar" y "Eliminar" actúan sobre todas las que la sesión ve.
 */
function fallidasDeLaSesion(userId: string, sucursalId: number | null): Promise<PendingOperation[]> {
  return db.pendingOperations
    .where('status')
    .equals('failed')
    .and(op => esDelUsuarioActivo(op, userId, sucursalId))
    .toArray()
}

/**
 * Reintentar las operaciones fallidas de la sesión activa.
 *
 * El alcance es obligatorio (#1264): sin él, "Reintentar" de B reseteaba las
 * fallidas de A, borrándoles el motivo que A todavía no había leído.
 */
export async function retryAllFailedOperations(
  userId: string,
  sucursalId: number | null
): Promise<number> {
  const now = new Date()

  return db.transaction('rw', [db.pendingOperations, db.syncEvents], async () => {
    const failed = await fallidasDeLaSesion(userId, sucursalId)
    for (const op of failed) {
      if (op.id) {
        await db.pendingOperations.update(op.id, {
          status: 'pending',
          retryCount: 0,
          lastError: undefined,
          rechazoRegalo: undefined,
          rechazoCombo: undefined,
          updatedAt: now
        })

        await db.syncEvents.add({
          operationId: op.id,
          type: 'operation_retried',
          details: 'Reintento masivo de operaciones fallidas',
          createdAt: now
        })
      }
    }
    return failed.length
  })
}

/**
 * Descartar (eliminar) las operaciones fallidas de la sesión activa.
 *
 * El alcance es obligatorio (#1264): sin él, "Eliminar" de B borraba para
 * siempre los pedidos fallidos de A. Cada operación borrada deja su rastro en
 * `syncEvents` (`operation_discarded`, con la operación entera y quién la
 * borró): un pedido descartado por error se puede reconstruir.
 */
export async function discardFailedOperations(
  userId: string,
  sucursalId: number | null
): Promise<number> {
  const now = new Date()

  return db.transaction('rw', [db.pendingOperations, db.syncEvents], async () => {
    const failed = (await fallidasDeLaSesion(userId, sucursalId)).filter(op => op.id != null)
    if (failed.length === 0) return 0

    await db.syncEvents.bulkAdd(failed.map(op => ({
      operationId: op.id,
      type: 'operation_discarded' as const,
      details: `Eliminada a mano: ${op.lastError ?? 'sin motivo'}`,
      operacion: op,
      descartadaPor: userId,
      createdAt: now
    })))
    await db.pendingOperations.bulkDelete(failed.map(op => op.id!))

    return failed.length
  })
}

/**
 * Elimina una operación puntual, sin importar su estado. A diferencia de
 * `markAsFailed`, que la deja en la cola visible en el panel de fallidas, esto
 * la saca de IndexedDB de verdad — lo que necesita un "Eliminar" que borra.
 */
export async function deletePendingOperation(id: number): Promise<void> {
  await db.pendingOperations.delete(id)
}

/**
 * Elimina varias operaciones puntuales por id.
 */
export async function deletePendingOperations(ids: number[]): Promise<number> {
  if (ids.length === 0) return 0
  await db.pendingOperations.bulkDelete(ids)
  return ids.length
}

export default db

/**
 * Puente para los E2E de Playwright.
 *
 * `page.evaluate(() => import('/src/lib/offlineDb.ts'))` sólo funciona
 * contra `vite dev`, que sirve las fuentes por ruta. El job e2e de CI corre
 * contra el `dist/` buildeado vía `vite preview` (playwright.config.ts) —
 * necesario para que el service worker se registre — y ahí esa ruta no
 * existe: el módulo está bundleado y minificado dentro de un chunk con hash.
 * Exponerlo acá le da a los tests un punto de entrada estable sin importar
 * qué server los sirve.
 *
 * Sólo en el dev server y en el build que el job `build` de CI arma con
 * `VITE_E2E_BRIDGE=true` (#1264). En producción quedaba colgado de `window`
 * con `clearAllData` y `discardFailedOperations`: cualquier script de la
 * página podía vaciar la cola sin pasar por la app. La condición va escrita
 * con `import.meta.env` literal para que Vite la reemplace y el build de
 * producción elimine el bloque entero.
 */
if (typeof window !== 'undefined' && (import.meta.env.DEV || import.meta.env.VITE_E2E_BRIDGE === 'true')) {
  (window as unknown as { __offlineDb?: Record<string, unknown> }).__offlineDb = {
    queueOperation,
    getPendingOperations,
    markAsProcessing,
    markAsCompleted,
    markAsFailed,
    anotarFalloDeRed,
    getOperationCounts,
    cleanupOldOperations,
    cleanupOldSyncEvents,
    cacheData,
    getCachedData,
    invalidateCache,
    cleanupExpiredCache,
    markRouteAsUsed,
    updateSavedRoute,
    deleteSavedRoute,
    isDbAvailable,
    getDbStats,
    clearAllData,
    getFailedOperations,
    retryFailedOperation,
    retryAllFailedOperations,
    discardFailedOperations,
    deletePendingOperation,
    deletePendingOperations,
    db,
  }
}

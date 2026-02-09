import { describe, it, expect, beforeEach } from 'vitest'
import {
  db,
  queueOperation,
  getPendingOperations,
  markAsProcessing,
  markAsCompleted,
  markAsFailed,
  getOperationCounts,
  cleanupOldOperations,
  cacheData,
  getCachedData,
  invalidateCache,
  saveOptimizedRoute,
  getSavedRoutes,
  findMatchingRoute,
  clearAllData,
  getDbStats,
  retryFailedOperation,
  getFailedOperations
} from './offlineDb'

describe('offlineDb', () => {
  beforeEach(async () => {
    await clearAllData()
  })

  // ---------------------------------------------------------------------------
  // queueOperation
  // ---------------------------------------------------------------------------

  describe('queueOperation', () => {
    it('creates an operation with correct fields', async () => {
      const payload = { clienteId: 'c1', total: 100 }
      const id = await queueOperation('CREATE_PEDIDO', payload, 'user-1', 3)

      expect(id).toBeTypeOf('number')
      const op = await db.pendingOperations.get(id!)
      expect(op).toBeDefined()
      expect(op!.type).toBe('CREATE_PEDIDO')
      expect(op!.payload).toEqual(payload)
      expect(op!.status).toBe('pending')
      expect(op!.retryCount).toBe(0)
      expect(op!.maxRetries).toBe(3)
      expect(op!.userId).toBe('user-1')
      expect(op!.hash).toMatch(/^CREATE_PEDIDO-/)
      expect(op!.createdAt).toBeInstanceOf(Date)
      expect(op!.updatedAt).toBeInstanceOf(Date)
    })

    it('creates a unique operation each call (hash includes timestamp)', async () => {
      const payload = { clienteId: 'c1', total: 100 }
      const id1 = await queueOperation('CREATE_PEDIDO', payload)
      const id2 = await queueOperation('CREATE_PEDIDO', payload)

      // Both should succeed because the hash includes Date.now()
      expect(id1).toBeTypeOf('number')
      expect(id2).toBeTypeOf('number')
      expect(id1).not.toBe(id2)
    })
  })

  // ---------------------------------------------------------------------------
  // getPendingOperations
  // ---------------------------------------------------------------------------

  describe('getPendingOperations', () => {
    it('returns pending ops and respects the limit parameter', async () => {
      await queueOperation('CREATE_PEDIDO', { n: 1 })
      await queueOperation('CREATE_PEDIDO', { n: 2 })
      await queueOperation('CREATE_PEDIDO', { n: 3 })

      const all = await getPendingOperations(10)
      expect(all).toHaveLength(3)

      const limited = await getPendingOperations(2)
      expect(limited).toHaveLength(2)
    })

    it('excludes operations where retryCount >= maxRetries', async () => {
      const id = await queueOperation('CREATE_PEDIDO', { n: 1 }, undefined, 1)
      // Fail it once — maxRetries is 1 so retryCount becomes 1 and status becomes 'failed'
      await markAsFailed(id!, 'network error')

      const pending = await getPendingOperations()
      expect(pending).toHaveLength(0)
    })
  })

  // ---------------------------------------------------------------------------
  // markAsProcessing
  // ---------------------------------------------------------------------------

  describe('markAsProcessing', () => {
    it('sets the status to processing', async () => {
      const id = await queueOperation('CREATE_PEDIDO', { n: 1 })
      await markAsProcessing(id!)

      const op = await db.pendingOperations.get(id!)
      expect(op!.status).toBe('processing')
    })
  })

  // ---------------------------------------------------------------------------
  // markAsCompleted
  // ---------------------------------------------------------------------------

  describe('markAsCompleted', () => {
    it('sets status to completed and creates a sync event', async () => {
      const id = await queueOperation('CREATE_PEDIDO', { n: 1 })
      await markAsCompleted(id!)

      const op = await db.pendingOperations.get(id!)
      expect(op!.status).toBe('completed')

      // Should have a sync_completed event
      const events = await db.syncEvents
        .where('operationId')
        .equals(id!)
        .toArray()
      const completedEvent = events.find(e => e.type === 'sync_completed')
      expect(completedEvent).toBeDefined()
    })
  })

  // ---------------------------------------------------------------------------
  // markAsFailed
  // ---------------------------------------------------------------------------

  describe('markAsFailed', () => {
    it('increments retryCount and records the error message', async () => {
      const id = await queueOperation('CREATE_PEDIDO', { n: 1 }, undefined, 5)
      await markAsFailed(id!, 'timeout')

      const op = await db.pendingOperations.get(id!)
      expect(op!.retryCount).toBe(1)
      expect(op!.lastError).toBe('timeout')
      // Still pending because retryCount (1) < maxRetries (5)
      expect(op!.status).toBe('pending')
    })

    it('sets status to failed permanently when maxRetries reached', async () => {
      const id = await queueOperation('CREATE_PEDIDO', { n: 1 }, undefined, 2)
      await markAsFailed(id!, 'first error')
      await markAsFailed(id!, 'second error')

      const op = await db.pendingOperations.get(id!)
      expect(op!.retryCount).toBe(2)
      expect(op!.status).toBe('failed')
      expect(op!.lastError).toBe('second error')
    })
  })

  // ---------------------------------------------------------------------------
  // getOperationCounts
  // ---------------------------------------------------------------------------

  describe('getOperationCounts', () => {
    it('returns correct counts per status', async () => {
      const id1 = await queueOperation('CREATE_PEDIDO', { n: 1 })
      const id2 = await queueOperation('CREATE_PEDIDO', { n: 2 })
      const id3 = await queueOperation('CREATE_PEDIDO', { n: 3 }, undefined, 1)
      await queueOperation('CREATE_PEDIDO', { n: 4 })

      await markAsProcessing(id1!)
      await markAsCompleted(id2!)
      // Fail id3 with maxRetries=1 so it becomes permanently failed
      await markAsFailed(id3!, 'err')
      // id4 stays pending

      const counts = await getOperationCounts()
      expect(counts.processing).toBe(1)
      expect(counts.completed).toBe(1)
      expect(counts.failed).toBe(1)
      expect(counts.pending).toBe(1)
    })
  })

  // ---------------------------------------------------------------------------
  // cleanupOldOperations
  // ---------------------------------------------------------------------------

  describe('cleanupOldOperations', () => {
    it('deletes completed operations older than the cutoff', async () => {
      const id = await queueOperation('CREATE_PEDIDO', { n: 1 })
      await markAsCompleted(id!)

      // Manually back-date the updatedAt to 10 days ago
      const tenDaysAgo = new Date()
      tenDaysAgo.setDate(tenDaysAgo.getDate() - 10)
      await db.pendingOperations.update(id!, { updatedAt: tenDaysAgo })

      const deletedCount = await cleanupOldOperations(7)
      expect(deletedCount).toBe(1)

      const op = await db.pendingOperations.get(id!)
      expect(op).toBeUndefined()
    })
  })

  // ---------------------------------------------------------------------------
  // cacheData / getCachedData
  // ---------------------------------------------------------------------------

  describe('cacheData', () => {
    it('creates a new cache entry', async () => {
      await cacheData('productos', [{ id: 1, name: 'Agua' }])

      const entry = await db.offlineCache.where('key').equals('productos').first()
      expect(entry).toBeDefined()
      expect(entry!.version).toBe(1)
      expect(entry!.data).toEqual([{ id: 1, name: 'Agua' }])
    })

    it('updates an existing entry and increments version', async () => {
      await cacheData('productos', [{ id: 1 }])
      await cacheData('productos', [{ id: 1 }, { id: 2 }])

      const entry = await db.offlineCache.where('key').equals('productos').first()
      expect(entry!.version).toBe(2)
      expect(entry!.data).toEqual([{ id: 1 }, { id: 2 }])
    })
  })

  describe('getCachedData', () => {
    it('returns null for expired data', async () => {
      // Cache with 1-minute expiry, then manually backdate expiresAt
      await cacheData('temp', { value: 42 }, 1)
      const entry = await db.offlineCache.where('key').equals('temp').first()
      const pastDate = new Date(Date.now() - 60_000)
      await db.offlineCache.update(entry!.id!, { expiresAt: pastDate })

      const result = await getCachedData('temp')
      expect(result).toBeNull()
    })
  })

  // ---------------------------------------------------------------------------
  // invalidateCache
  // ---------------------------------------------------------------------------

  describe('invalidateCache', () => {
    it('removes the cache entry for the given key', async () => {
      await cacheData('productos', [{ id: 1 }])
      await invalidateCache('productos')

      const result = await getCachedData('productos')
      expect(result).toBeNull()
    })
  })

  // ---------------------------------------------------------------------------
  // saveOptimizedRoute / getSavedRoutes / findMatchingRoute
  // ---------------------------------------------------------------------------

  describe('saveOptimizedRoute', () => {
    it('creates a route record', async () => {
      const id = await saveOptimizedRoute({
        nombre: 'Ruta Norte',
        transportistaId: 't1',
        clienteIds: ['c1', 'c2', 'c3'],
        ordenOptimizado: [0, 2, 1],
        distanciaTotal: 15000,
        duracionEstimada: 3600
      })

      expect(id).toBeTypeOf('number')
      const route = await db.savedRoutes.get(id)
      expect(route).toBeDefined()
      expect(route!.nombre).toBe('Ruta Norte')
      expect(route!.clienteIds).toEqual(['c1', 'c2', 'c3'])
      expect(route!.createdAt).toBeInstanceOf(Date)
    })
  })

  describe('getSavedRoutes', () => {
    it('returns routes filtered by transportistaId', async () => {
      await saveOptimizedRoute({
        nombre: 'Ruta A',
        transportistaId: 't1',
        clienteIds: ['c1'],
        ordenOptimizado: [0]
      })
      await saveOptimizedRoute({
        nombre: 'Ruta B',
        transportistaId: 't2',
        clienteIds: ['c2'],
        ordenOptimizado: [0]
      })
      await saveOptimizedRoute({
        nombre: 'Ruta C',
        transportistaId: 't1',
        clienteIds: ['c3'],
        ordenOptimizado: [0]
      })

      const routes = await getSavedRoutes('t1')
      expect(routes).toHaveLength(2)
      expect(routes.every(r => r.transportistaId === 't1')).toBe(true)
    })
  })

  describe('findMatchingRoute', () => {
    it('finds a route with high client-set similarity', async () => {
      await saveOptimizedRoute({
        nombre: 'Ruta Norte',
        transportistaId: 't1',
        clienteIds: ['c1', 'c2', 'c3', 'c4', 'c5'],
        ordenOptimizado: [0, 1, 2, 3, 4],
        distanciaTotal: 20000
      })

      // Search with 4/5 matching clients — Jaccard = 4/6 ≈ 66.7%
      // Default tolerance is 20% so threshold = 80%, won't match
      // Use tolerance 40% so threshold = 60%, should match
      const match = await findMatchingRoute('t1', ['c1', 'c2', 'c3', 'c4', 'c6'], 40)
      expect(match).not.toBeNull()
      expect(match!.nombre).toBe('Ruta Norte')
    })

    it('returns null when no route has sufficient similarity', async () => {
      await saveOptimizedRoute({
        nombre: 'Ruta Norte',
        transportistaId: 't1',
        clienteIds: ['c1', 'c2', 'c3'],
        ordenOptimizado: [0, 1, 2]
      })

      // Completely different clients — similarity = 0%
      const match = await findMatchingRoute('t1', ['c10', 'c20', 'c30'])
      expect(match).toBeNull()
    })
  })

  // ---------------------------------------------------------------------------
  // clearAllData
  // ---------------------------------------------------------------------------

  describe('clearAllData', () => {
    it('empties all tables', async () => {
      await queueOperation('CREATE_PEDIDO', { n: 1 })
      await cacheData('k', 'v')
      await saveOptimizedRoute({
        nombre: 'R',
        transportistaId: 't1',
        clienteIds: ['c1'],
        ordenOptimizado: [0]
      })

      await clearAllData()

      const stats = await getDbStats()
      expect(stats.pendingOperations).toBe(0)
      expect(stats.cacheEntries).toBe(0)
      expect(stats.savedRoutes).toBe(0)
      expect(stats.syncEvents).toBe(0)
    })
  })

  // ---------------------------------------------------------------------------
  // getDbStats
  // ---------------------------------------------------------------------------

  describe('getDbStats', () => {
    it('returns correct counts for all tables', async () => {
      await queueOperation('CREATE_PEDIDO', { n: 1 })
      await queueOperation('UPDATE_PEDIDO', { n: 2 })
      await cacheData('productos', [])
      await saveOptimizedRoute({
        nombre: 'R',
        transportistaId: 't1',
        clienteIds: ['c1'],
        ordenOptimizado: [0]
      })

      const stats = await getDbStats()
      // 2 operations
      expect(stats.pendingOperations).toBe(2)
      expect(stats.cacheEntries).toBe(1)
      expect(stats.savedRoutes).toBe(1)
      // Each queueOperation adds a sync_started event
      expect(stats.syncEvents).toBe(2)
      expect(stats.estimatedSizeMB).toBeTypeOf('number')
    })
  })

  // ---------------------------------------------------------------------------
  // retryFailedOperation / getFailedOperations
  // ---------------------------------------------------------------------------

  describe('retryFailedOperation', () => {
    it('resets a failed operation back to pending with retryCount 0', async () => {
      const id = await queueOperation('CREATE_PEDIDO', { n: 1 }, undefined, 1)
      await markAsFailed(id!, 'network error')

      // Confirm it is now failed
      let op = await db.pendingOperations.get(id!)
      expect(op!.status).toBe('failed')

      await retryFailedOperation(id!)

      op = await db.pendingOperations.get(id!)
      expect(op!.status).toBe('pending')
      expect(op!.retryCount).toBe(0)
    })

    it('throws when the operation is not in failed state', async () => {
      const id = await queueOperation('CREATE_PEDIDO', { n: 1 })
      await expect(retryFailedOperation(id!)).rejects.toThrow(
        'Operación no encontrada o no está en estado fallido'
      )
    })
  })

  describe('getFailedOperations', () => {
    it('returns only operations with failed status', async () => {
      const id1 = await queueOperation('CREATE_PEDIDO', { n: 1 }, undefined, 1)
      await queueOperation('CREATE_PEDIDO', { n: 2 }) // stays pending
      await markAsFailed(id1!, 'err')

      const failed = await getFailedOperations()
      expect(failed).toHaveLength(1)
      expect(failed[0].id).toBe(id1)
      expect(failed[0].status).toBe('failed')
    })
  })
})

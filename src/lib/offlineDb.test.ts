import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
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
  clearAllData,
  limpiarCachesDeLectura,
  getDbStats,
  retryFailedOperation,
  retryAllFailedOperations,
  reintentarSinRegalos,
  getFailedOperations,
  getMaxFailedOperationId,
  discardFailedOperations,
  deletePendingOperation,
  deletePendingOperations,
  cleanupOldSyncEvents,
  pedirAlmacenamientoPersistente,
  anotarFalloDeRed
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

    it('always creates a new operation, even with an identical payload (no dedup)', async () => {
      const payload = { clienteId: 'c1', total: 100 }
      const id1 = await queueOperation('CREATE_PEDIDO', payload)
      const id2 = await queueOperation('CREATE_PEDIDO', payload)

      expect(id1).toBeTypeOf('number')
      expect(id2).toBeTypeOf('number')
      expect(id1).not.toBe(id2)

      const all = await getPendingOperations(10)
      expect(all).toHaveLength(2)
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

    /**
     * TELÉFONO COMPARTIDO. IndexedDB es del dispositivo, no de la sesión, y el
     * logout no la toca (a propósito: una cola borrada es un pedido perdido).
     * Sin filtrar por dueño, el usuario B veía los pedidos encolados por A, los
     * replayaba, el guard de la mig 219 se los rechazaba con 42501 y
     * terminaban en `failed` sin que A se enterara.
     */
    describe('filtro por dueño (usuario y sucursal)', () => {
      it('no devuelve las operaciones de otro usuario', async () => {
        await queueOperation('CREATE_PEDIDO', { n: 'de A' }, 'user-A', 5, 1)
        await queueOperation('CREATE_PEDIDO', { n: 'de B' }, 'user-B', 5, 1)

        const deB = await getPendingOperations(10, 'user-B', 1)
        expect(deB).toHaveLength(1)
        expect(deB[0].payload).toEqual({ n: 'de B' })
      })

      it('no devuelve las operaciones de otra sucursal', async () => {
        await queueOperation('CREATE_PEDIDO', { n: 'tucuman' }, 'user-A', 5, 1)
        await queueOperation('CREATE_PEDIDO', { n: 'taco pozo' }, 'user-A', 5, 2)

        const sucursal2 = await getPendingOperations(10, 'user-A', 2)
        expect(sucursal2).toHaveLength(1)
        expect(sucursal2[0].payload).toEqual({ n: 'taco pozo' })
      })

      it('sigue mostrando las que no tienen dueño anotado', async () => {
        // Encoladas antes de que la cola registrara userId/sucursalId.
        // Esconderlas las dejaría huérfanas para siempre; que se vean es lo que
        // permite sincronizarlas o descartarlas.
        await queueOperation('UPDATE_PRODUCTO', { n: 'vieja' })

        const deB = await getPendingOperations(10, 'user-B', 1)
        expect(deB).toHaveLength(1)
      })

      it('sin filtro devuelve todo, como antes', async () => {
        await queueOperation('CREATE_PEDIDO', { n: 1 }, 'user-A', 5, 1)
        await queueOperation('CREATE_PEDIDO', { n: 2 }, 'user-B', 5, 2)

        expect(await getPendingOperations(10)).toHaveLength(2)
      })
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

    it('con terminal:true no gasta los reintentos que quedan', async () => {
      // Para lo que reintentar no puede arreglar: la clave de idempotencia ya
      // la tiene otro pedido. Queda en el panel de fallidas, que es donde
      // alguien puede decidir qué hacer con ella.
      const id = await queueOperation('CREATE_PEDIDO', { n: 1 }, undefined, 5)
      await markAsFailed(id!, 'la clave ya la tiene otro pedido', { terminal: true })

      const op = await db.pendingOperations.get(id!)
      expect(op!.status).toBe('failed')
      expect(op!.retryCount).toBe(5)
      expect(await getPendingOperations()).toHaveLength(0)
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

    it('#1264: no resucita una operación que otra pestaña ya completó', async () => {
      // Dos pestañas leen la misma operación pendiente. La A la sincroniza; la
      // B falla (red, stock con su lista vieja) y la marcaba fallida encima del
      // `completed`: volvía a la cola un pedido que ya estaba en el servidor.
      const id = await queueOperation('CREATE_PEDIDO', { n: 1 }, 'user-A', 5, 1)
      await markAsCompleted(id)

      await markAsFailed(id, 'TypeError: Failed to fetch')
      await markAsFailed(id, 'otro motivo', { terminal: true })

      const op = (await db.pendingOperations.get(id))!
      expect(op.status).toBe('completed')
      expect(op.retryCount).toBe(0)
      expect(op.lastError).toBeUndefined()
      expect(await getPendingOperations(10, 'user-A', 1)).toHaveLength(0)
      expect(await getFailedOperations(10, 'user-A', 1)).toHaveLength(0)
    })
  })

  // ---------------------------------------------------------------------------
  // #1264: un fallo sin respuesta del servidor no gasta reintentos
  // ---------------------------------------------------------------------------

  /**
   * Decisión del dueño (#1264, opción A). Con una señal que "está" pero no pasa
   * datos, cada auto-sync (ventana de 30 s) gastaba un reintento: a los ~2,5
   * minutos el pedido quedaba `failed`, salía del contador y sólo quedaba el
   * banner rojo. Ahora un fallo sin respuesta del servidor no gasta: el pedido
   * sigue pendiente, con el motivo, y se reintenta mientras haya conexión.
   */
  describe('#1264: anotarFalloDeRed', () => {
    const MOTIVO = 'Sin conexión: no se pudo confirmar el alta del pedido.'

    it('no gasta reintentos: sigue pendiente con el motivo aunque falle más veces que maxRetries', async () => {
      const id = await queueOperation('CREATE_PEDIDO', { n: 1 }, 'user-A', 2, 1)

      for (let i = 0; i < 5; i++) await anotarFalloDeRed(id, MOTIVO)

      const op = (await db.pendingOperations.get(id))!
      expect(op.status).toBe('pending')
      expect(op.retryCount).toBe(0)
      expect(op.lastError).toBe(MOTIVO)
      expect((await getPendingOperations(10, 'user-A', 1)).map(o => o.id)).toEqual([id])
      expect(await getFailedOperations(10, 'user-A', 1)).toHaveLength(0)

      const intentos = await db.syncEvents.where('operationId').equals(id).filter(e => e.type === 'operation_retried').count()
      expect(intentos).toBe(5)
    })

    it('no resucita una operación que otra pestaña ya completó', async () => {
      const id = await queueOperation('CREATE_PEDIDO', { n: 1 }, 'user-A', 5, 1)
      await markAsCompleted(id)

      await anotarFalloDeRed(id, MOTIVO)

      const op = (await db.pendingOperations.get(id))!
      expect(op.status).toBe('completed')
      expect(op.lastError).toBeUndefined()
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
  // clearAllData
  // ---------------------------------------------------------------------------

  describe('clearAllData', () => {
    it('empties all tables', async () => {
      await queueOperation('CREATE_PEDIDO', { n: 1 })
      await cacheData('k', 'v')
      await db.savedRoutes.add({
        nombre: 'R',
        transportistaId: 't1',
        clienteIds: ['c1'],
        ordenOptimizado: [0],
        createdAt: new Date(),
        updatedAt: new Date()
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
  // limpiarCachesDeLectura
  // ---------------------------------------------------------------------------

  describe('limpiarCachesDeLectura', () => {
    it('vacía offlineCache y savedRoutes pero deja pendingOperations intacta', async () => {
      const opId = await queueOperation('CREATE_PEDIDO', { n: 1 }, 'user-1')
      await cacheData('productos', [{ id: 1 }])
      await db.savedRoutes.add({
        nombre: 'R',
        transportistaId: 't1',
        clienteIds: ['c1'],
        ordenOptimizado: [0],
        createdAt: new Date(),
        updatedAt: new Date()
      })

      await limpiarCachesDeLectura()

      const stats = await getDbStats()
      expect(stats.cacheEntries).toBe(0)
      expect(stats.savedRoutes).toBe(0)
      expect(stats.pendingOperations).toBe(1)
      expect(await db.pendingOperations.get(opId!)).toBeDefined()
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
      await db.savedRoutes.add({
        nombre: 'R',
        transportistaId: 't1',
        clienteIds: ['c1'],
        ordenOptimizado: [0],
        createdAt: new Date(),
        updatedAt: new Date()
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

  // ---------------------------------------------------------------------------
  // reintentarSinRegalos (#1153)
  // ---------------------------------------------------------------------------

  describe('reintentarSinRegalos', () => {
    const payloadConRegalo = {
      offlineUuid: 'uuid-1153',
      clienteId: '10',
      total: 1000,
      items: [
        { productoId: '1', cantidad: 10, precioUnitario: 100 },
        { productoId: '2', cantidad: 4, precioUnitario: 0, esBonificacion: true, promocionId: '15' },
      ],
      origenes: [
        { producto_id: '1', es_bonificacion: false, origen_precio: 'lista' },
        { producto_id: '2', es_bonificacion: true, origen_precio: 'bonificacion' },
      ],
    }

    const rechazada = async () => {
      const id = await queueOperation('CREATE_PEDIDO', payloadConRegalo, undefined, 5)
      await markAsFailed(id!, 'La promo "X" está desactivada', { terminal: true, rechazoRegalo: true })
      return id!
    }

    it('markAsFailed deja la marca, y un fallo posterior sin ella la borra', async () => {
      const id = await rechazada()
      expect((await db.pendingOperations.get(id))!.rechazoRegalo).toBe(true)
      await markAsFailed(id, 'Failed to fetch')
      expect((await db.pendingOperations.get(id))!.rechazoRegalo).toBeUndefined()
    })

    it('vuelve la operación a pending sin las líneas de regalo, con la misma clave', async () => {
      const id = await rechazada()
      await reintentarSinRegalos(id)

      const op = (await db.pendingOperations.get(id))!
      expect(op.status).toBe('pending')
      expect(op.retryCount).toBe(0)
      expect(op.lastError).toBeUndefined()
      expect(op.rechazoRegalo).toBeUndefined()
      expect(op.payload.offlineUuid).toBe('uuid-1153')
      expect(op.payload.total).toBe(1000)
      expect(op.payload.items).toEqual([{ productoId: '1', cantidad: 10, precioUnitario: 100 }])
      expect(op.payload.origenes).toEqual([{ producto_id: '1', es_bonificacion: false, origen_precio: 'lista' }])
      expect(op.payload.regalosQuitados).toBe(true)

      const eventos = await db.syncEvents.where('operationId').equals(id).toArray()
      expect(eventos.some(e => e.type === 'operation_retried' && e.details === 'Reintento sin el regalo')).toBe(true)
    })

    it('rechaza una operación sin la marca o que no está fallida, y no la toca', async () => {
      const sinMarca = await queueOperation('CREATE_PEDIDO', payloadConRegalo, undefined, 5)
      await markAsFailed(sinMarca!, 'otro rechazo', { terminal: true })
      await expect(reintentarSinRegalos(sinMarca!)).rejects.toThrow()
      expect((await db.pendingOperations.get(sinMarca!))!.payload).toEqual(payloadConRegalo)

      const pendiente = await queueOperation('CREATE_PEDIDO', payloadConRegalo, undefined, 5)
      await expect(reintentarSinRegalos(pendiente!)).rejects.toThrow()
      expect((await db.pendingOperations.get(pendiente!))!.status).toBe('pending')
    })

    it('el reintento normal, uno o todos, limpia la marca', async () => {
      const id1 = await rechazada()
      const id2 = await rechazada()
      await retryFailedOperation(id1)
      expect((await db.pendingOperations.get(id1))!.rechazoRegalo).toBeUndefined()
      await retryAllFailedOperations('user-A', 1)
      expect((await db.pendingOperations.get(id2))!.rechazoRegalo).toBeUndefined()
      // el reintento normal no le quita el regalo
      expect((await db.pendingOperations.get(id2))!.payload).toEqual(payloadConRegalo)
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

  // ---------------------------------------------------------------------------
  // deletePendingOperation / deletePendingOperations
  // ---------------------------------------------------------------------------

  describe('deletePendingOperation', () => {
    it('removes the operation from IndexedDB regardless of status', async () => {
      const id = await queueOperation('CREATE_PEDIDO', { n: 1 })

      await deletePendingOperation(id)

      expect(await db.pendingOperations.get(id)).toBeUndefined()
    })
  })

  describe('deletePendingOperations', () => {
    it('removes every listed operation and returns the count', async () => {
      const id1 = await queueOperation('CREATE_PEDIDO', { n: 1 })
      const id2 = await queueOperation('UPDATE_PRODUCTO', { n: 2 })
      const id3 = await queueOperation('CREATE_PEDIDO', { n: 3 }) // not deleted

      const deletedCount = await deletePendingOperations([id1, id2])

      expect(deletedCount).toBe(2)
      expect(await db.pendingOperations.get(id1)).toBeUndefined()
      expect(await db.pendingOperations.get(id2)).toBeUndefined()
      expect(await db.pendingOperations.get(id3)).toBeDefined()
    })

    it('does nothing for an empty list', async () => {
      expect(await deletePendingOperations([])).toBe(0)
    })
  })

  // ---------------------------------------------------------------------------
  // #1264: el panel de fallidas es de la sesión activa
  // ---------------------------------------------------------------------------

  /**
   * DISPOSITIVO COMPARTIDO. `getPendingOperations` ya filtraba por dueño, pero
   * las fallidas no: el usuario B veía el `lastError` de A (puede nombrar
   * clientes), y "Reintentar" y "Eliminar" actuaban sobre las operaciones de
   * todos los usuarios y sucursales del teléfono. Eliminar borraba para siempre
   * los pedidos de A sin que A se enterara.
   */
  describe('#1264: fallidas acotadas al usuario y la sucursal activos', () => {
    async function fallida(payload: Record<string, unknown>, userId?: string, sucursalId?: number) {
      const id = await queueOperation('CREATE_PEDIDO', payload, userId, 1, sucursalId)
      await markAsFailed(id, `rechazo de ${String(payload.n)}`)
      return id
    }

    it('getFailedOperations no devuelve las de otro usuario ni las de otra sucursal', async () => {
      await fallida({ n: 'A' }, 'user-A', 1)
      const deB = await fallida({ n: 'B' }, 'user-B', 1)
      await fallida({ n: 'B en otra sucursal' }, 'user-B', 2)

      const fallidas = await getFailedOperations(10, 'user-B', 1)
      expect(fallidas.map(op => op.id)).toEqual([deB])
    })

    it('getFailedOperations sigue mostrando las fallidas sin dueño anotado', async () => {
      const vieja = await fallida({ n: 'vieja' })
      expect((await getFailedOperations(10, 'user-B', 1)).map(op => op.id)).toEqual([vieja])
    })

    // PLT-N8 (#1305): una heredada sin `userId` anotado, pero con el
    // `usuarioId` de quien la tomó dentro del payload, es de ese usuario. Antes
    // la veían, reintentaban y borraban todos los del teléfono.
    describe('heredadas sin userId: el dueño sale del payload', () => {
      it('sólo las ve el usuario del payload (fallidas, pendientes y conteos)', async () => {
        const heredada = await fallida({ n: 'heredada', usuarioId: 'user-A' }, undefined, 1)
        const pendiente = await queueOperation('CREATE_PEDIDO', { n: 'pendiente', usuarioId: 'user-A' }, undefined, 5, 1)

        expect((await getFailedOperations(10, 'user-A', 1)).map(op => op.id)).toEqual([heredada])
        expect(await getFailedOperations(10, 'user-B', 1)).toEqual([])
        expect((await getPendingOperations(10, 'user-A', 1)).map(op => op.id)).toContain(pendiente)
        expect(await getPendingOperations(10, 'user-B', 1)).toEqual([])
        expect((await getOperationCounts('user-A', 1)).failed).toBe(1)
        expect(await getOperationCounts('user-B', 1)).toMatchObject({ failed: 0, pending: 0 })
        expect(await getMaxFailedOperationId('user-B', 1)).toBe(0)
      })

      it('"Reintentar" y "Eliminar" de otro usuario no la tocan', async () => {
        const heredada = await fallida({ n: 'heredada', usuarioId: 'user-A' }, undefined, 1)

        expect(await retryAllFailedOperations('user-B', 1)).toBe(0)
        expect(await discardFailedOperations('user-B', 1)).toBe(0)

        const op = (await db.pendingOperations.get(heredada))!
        expect(op.status).toBe('failed')
        expect(op.lastError).toBe('rechazo de heredada')
      })

      it('su dueño sí la reintenta y la borra, con rastro', async () => {
        const heredada = await fallida({ n: 'heredada', usuarioId: 'user-A' }, undefined, 1)

        expect(await retryAllFailedOperations('user-A', 1)).toBe(1)
        expect((await db.pendingOperations.get(heredada))!.status).toBe('pending')

        await markAsFailed(heredada, 'otra vez')
        expect(await discardFailedOperations('user-A', 1)).toBe(1)
        expect(await db.pendingOperations.get(heredada)).toBeUndefined()
        const rastro = await db.syncEvents.filter(e => e.type === 'operation_discarded').toArray()
        expect(rastro).toHaveLength(1)
        expect(rastro[0].operacion?.payload).toMatchObject({ usuarioId: 'user-A' })
      })

      it('el userId anotado manda sobre el del payload', async () => {
        // Así encola hoy `useOfflineSync`: el dueño es `pedidoData.usuarioId ?? sesión`.
        const id = await fallida({ n: 'x', usuarioId: 'user-A' }, 'user-B', 1)

        expect(await getFailedOperations(10, 'user-A', 1)).toEqual([])
        expect((await getFailedOperations(10, 'user-B', 1)).map(op => op.id)).toEqual([id])
      })

      it('sin dueño en ningún lado sigue visible para todos: no se esconde ni se pierde', async () => {
        const huerfana = await fallida({ n: 'huerfana' })
        const conVacio = await fallida({ n: 'vacio', usuarioId: '' })
        const conNumero = await fallida({ n: 'numero', usuarioId: 42 })

        for (const usuario of ['user-A', 'user-B']) {
          const ids = (await getFailedOperations(10, usuario, 1)).map(op => op.id)
          expect(ids).toEqual([huerfana, conVacio, conNumero])
        }
      })

      it('una merma heredada (sin userId ni usuarioId en el payload) sigue visible para todos', async () => {
        // Las mermas no llevaban dueño: ni columna ni `usuarioId` en el payload.
        const merma = await queueOperation('UPDATE_PRODUCTO', { productoId: '9', cantidad: 2, motivo: 'vencido' }, undefined, 1, 1)
        await markAsFailed(merma, 'rechazo de merma')

        for (const usuario of ['user-A', 'user-B']) {
          expect((await getFailedOperations(10, usuario, 1)).map(op => op.id)).toEqual([merma])
        }
        expect((await getOperationCounts('user-B', 1)).failed).toBe(1)
      })

      it('el paso del tiempo no borra una heredada sin dueño ni una con dueño', async () => {
        const huerfana = await fallida({ n: 'huerfana' })
        const deA = await fallida({ n: 'de A', usuarioId: 'user-A' }, undefined, 1)
        const vieja = new Date(Date.now() - 400 * 24 * 60 * 60 * 1000)
        await db.pendingOperations.update(huerfana, { createdAt: vieja, updatedAt: vieja })
        await db.pendingOperations.update(deA, { createdAt: vieja, updatedAt: vieja })

        await cleanupOldOperations()

        expect(await db.pendingOperations.get(huerfana)).toBeDefined()
        expect(await db.pendingOperations.get(deA)).toBeDefined()
      })
    })

    it('getMaxFailedOperationId mira todas las fallidas de la sesión, no una muestra', async () => {
      await fallida({ n: 'A' }, 'user-A', 1)
      let ultimaDeB = 0
      for (let n = 0; n < 12; n++) ultimaDeB = await fallida({ n: `B${n}` }, 'user-B', 1)
      const deAdespues = await fallida({ n: 'A2' }, 'user-A', 1)

      // El límite de 10 deja afuera a las últimas: el máximo no sale de ahí.
      const muestra = await getFailedOperations(10, 'user-B', 1)
      expect(muestra).toHaveLength(10)
      expect(Math.max(...muestra.map(op => op.id!))).toBeLessThan(ultimaDeB)

      expect(await getMaxFailedOperationId('user-B', 1)).toBe(ultimaDeB)
      expect(await getMaxFailedOperationId('user-A', 1)).toBe(deAdespues)
      expect(await getMaxFailedOperationId('user-C', 1)).toBe(0)
    })

    it('el límite se aplica después del filtro', async () => {
      // Con el límite antes del filtro, las 3 de A llenaban el cupo y la de B
      // no aparecía.
      await fallida({ n: 'A1' }, 'user-A', 1)
      await fallida({ n: 'A2' }, 'user-A', 1)
      await fallida({ n: 'A3' }, 'user-A', 1)
      const deB = await fallida({ n: 'B' }, 'user-B', 1)

      expect((await getFailedOperations(1, 'user-B', 1)).map(op => op.id)).toEqual([deB])
    })

    it('getOperationCounts cuenta sólo lo de la sesión activa', async () => {
      await fallida({ n: 'A' }, 'user-A', 1)
      await queueOperation('CREATE_PEDIDO', { n: 'A pendiente' }, 'user-A', 5, 1)
      await fallida({ n: 'B' }, 'user-B', 1)

      const deB = await getOperationCounts('user-B', 1)
      expect(deB.failed).toBe(1)
      expect(deB.pending).toBe(0)
      // Sin alcance, como antes: todo el dispositivo.
      expect((await getOperationCounts()).failed).toBe(2)
    })

    it('retryAllFailedOperations reintenta sólo las de la sesión activa', async () => {
      const deA = await fallida({ n: 'A' }, 'user-A', 1)
      const deB = await fallida({ n: 'B' }, 'user-B', 1)

      expect(await retryAllFailedOperations('user-B', 1)).toBe(1)

      expect((await db.pendingOperations.get(deB))!.status).toBe('pending')
      const opA = (await db.pendingOperations.get(deA))!
      expect(opA.status).toBe('failed')
      expect(opA.lastError).toBe('rechazo de A')
    })

    it('discardFailedOperations borra sólo las de la sesión activa', async () => {
      const deA = await fallida({ n: 'A' }, 'user-A', 1)
      const deBotraSucursal = await fallida({ n: 'B2' }, 'user-B', 2)
      const deB = await fallida({ n: 'B' }, 'user-B', 1)

      expect(await discardFailedOperations('user-B', 1)).toBe(1)

      expect(await db.pendingOperations.get(deB)).toBeUndefined()
      expect(await db.pendingOperations.get(deA)).toBeDefined()
      expect(await db.pendingOperations.get(deBotraSucursal)).toBeDefined()
    })

    it('discardFailedOperations deja rastro de lo que borró: la operación entera y quién la borró', async () => {
      // `syncEvents` no guardaba el payload: un pedido descartado por error no
      // se podía reconstruir.
      const payload = { n: 'B', clienteId: '77', total: 1500, offlineUuid: 'uuid-descartada' }
      const deB = await fallida(payload, 'user-B', 1)

      await discardFailedOperations('user-B', 1)

      const rastro = await db.syncEvents.where('operationId').equals(deB).toArray()
      const descarte = rastro.find(e => e.type === 'operation_discarded')
      expect(descarte).toBeDefined()
      expect(descarte!.descartadaPor).toBe('user-B')
      expect(descarte!.operacion).toMatchObject({
        id: deB,
        type: 'CREATE_PEDIDO',
        status: 'failed',
        userId: 'user-B',
        sucursalId: 1,
        lastError: 'rechazo de B',
        payload,
      })
    })
  })

  // ---------------------------------------------------------------------------
  // #1264: syncEvents no crece sin límite
  // ---------------------------------------------------------------------------

  describe('#1264: cleanupOldSyncEvents', () => {
    const DIA = 24 * 60 * 60 * 1000
    const haceDias = (dias: number) => new Date(Date.now() - dias * DIA)

    it('borra los eventos de más de 7 días y conserva los recientes', async () => {
      await db.syncEvents.bulkAdd([
        { type: 'sync_started', createdAt: haceDias(8) },
        { type: 'sync_completed', createdAt: haceDias(30) },
        { type: 'sync_started', createdAt: haceDias(1) },
      ])

      expect(await cleanupOldSyncEvents()).toBe(2)

      const quedan = await db.syncEvents.toArray()
      expect(quedan).toHaveLength(1)
      expect(quedan[0].createdAt.getTime()).toBeGreaterThan(haceDias(2).getTime())
    })

    it('el rastro de una operación borrada dura 90 días, no 7', async () => {
      await db.syncEvents.bulkAdd([
        { type: 'operation_discarded', createdAt: haceDias(30) },
        { type: 'operation_discarded', createdAt: haceDias(91) },
      ])

      await cleanupOldSyncEvents()

      const quedan = await db.syncEvents.toArray()
      expect(quedan).toHaveLength(1)
      expect(quedan[0].createdAt.getTime()).toBeGreaterThan(haceDias(31).getTime())
    })

    it('con más de 1000 eventos recientes conserva los 1000 más nuevos', async () => {
      // Una caja vende cientos de veces por día y cada venta deja dos eventos:
      // la ventana de 7 días sola no alcanza para acotarla.
      const base = Date.now() - 60 * 60 * 1000
      await db.syncEvents.bulkAdd(
        Array.from({ length: 1005 }, (_, i) => ({
          type: 'sync_started' as const,
          details: `evento ${i}`,
          createdAt: new Date(base + i * 1000),
        }))
      )
      await db.syncEvents.add({ type: 'operation_discarded', createdAt: new Date(base - 1000) })

      expect(await cleanupOldSyncEvents()).toBe(5)

      expect(await db.syncEvents.count()).toBe(1001)
      // Se fueron los más viejos, y el rastro de lo borrado no cuenta para el tope.
      expect(await db.syncEvents.filter(e => e.details === 'evento 0').count()).toBe(0)
      expect(await db.syncEvents.filter(e => e.details === 'evento 1004').count()).toBe(1)
      expect(await db.syncEvents.filter(e => e.type === 'operation_discarded').count()).toBe(1)
    })
  })

  // ---------------------------------------------------------------------------
  // #1264: almacenamiento persistente
  // ---------------------------------------------------------------------------

  /**
   * Sin `navigator.storage.persist()` el navegador puede borrar IndexedDB bajo
   * presión de espacio, y con ella la cola: un pedido tomado sin señal se
   * pierde sin que nadie se entere.
   */
  describe('#1264: pedirAlmacenamientoPersistente', () => {
    const storageOriginal = Object.getOwnPropertyDescriptor(navigator, 'storage')

    function simularStorage(storage: unknown) {
      Object.defineProperty(navigator, 'storage', { value: storage, configurable: true })
    }

    afterEach(() => {
      if (storageOriginal) Object.defineProperty(navigator, 'storage', storageOriginal)
      else delete (navigator as unknown as Record<string, unknown>).storage
    })

    it('lo pide si todavía no es persistente', async () => {
      const persist = vi.fn().mockResolvedValue(true)
      simularStorage({ persisted: vi.fn().mockResolvedValue(false), persist })

      expect(await pedirAlmacenamientoPersistente()).toBe(true)
      expect(persist).toHaveBeenCalledTimes(1)
    })

    it('no lo vuelve a pedir si ya lo es', async () => {
      const persist = vi.fn().mockResolvedValue(true)
      simularStorage({ persisted: vi.fn().mockResolvedValue(true), persist })

      expect(await pedirAlmacenamientoPersistente()).toBe(true)
      expect(persist).not.toHaveBeenCalled()
    })

    it('sin la API (o si falla) devuelve false y no rompe', async () => {
      simularStorage(undefined)
      expect(await pedirAlmacenamientoPersistente()).toBe(false)

      simularStorage({ persisted: vi.fn().mockRejectedValue(new Error('SecurityError')), persist: vi.fn() })
      expect(await pedirAlmacenamientoPersistente()).toBe(false)
    })

    it('el primer encolado de la carga lo pide, una sola vez', async () => {
      const persist = vi.fn().mockResolvedValue(true)
      simularStorage({ persisted: vi.fn().mockResolvedValue(false), persist })
      // Módulo fresco: el pedido se recuerda por carga de la página.
      vi.resetModules()
      const fresco = await import('./offlineDb')
      try {
        await fresco.queueOperation('CREATE_PEDIDO', { n: 1 }, 'user-A', 5, 1)
        await fresco.queueOperation('CREATE_PEDIDO', { n: 2 }, 'user-A', 5, 1)
        await vi.waitFor(() => expect(persist).toHaveBeenCalledTimes(1))
      } finally {
        fresco.db.close()
      }
    })
  })
})

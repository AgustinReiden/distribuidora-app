/**
 * useOfflineQueue - Hook para manejo de cola de sincronización offline
 *
 * Proporciona:
 * - Cola persistente en IndexedDB (sobrevive cierre de app)
 * - Sincronización automática cuando vuelve internet
 * - Reintentos con backoff exponencial
 * - Detección de duplicados
 * - Estado visual para UI
 */

import { useState, useEffect, useCallback, useRef } from 'react'
import {
  db,
  queueOperation,
  getPendingOperations,
  markAsProcessing,
  markAsCompleted,
  markAsFailed,
  getOperationCounts,
  cleanupOldOperations,
  type OperationType,
  type PendingOperation
} from '../lib/offlineDb'
import { supabase } from './supabase/base'
import { logger } from '../utils/logger'

// =============================================================================
// TIPOS
// =============================================================================

export type SyncStatus = 'online' | 'offline' | 'syncing' | 'error'

export interface SyncState {
  status: SyncStatus
  isOnline: boolean
  pendingCount: number
  failedCount: number
  lastSyncAt: Date | null
  lastError: string | null
}

export interface UseOfflineQueueReturn {
  /** Estado actual de sincronización */
  syncState: SyncState
  /** Agregar operación a la cola */
  enqueue: (type: OperationType, payload: Record<string, unknown>) => Promise<number | null>
  /** Forzar sincronización */
  syncNow: () => Promise<void>
  /** Reintentar operaciones fallidas */
  retryFailed: () => Promise<void>
  /** Limpiar operaciones completadas */
  cleanup: () => Promise<number>
  /** Obtener operaciones pendientes */
  getPending: () => Promise<PendingOperation[]>
}

// =============================================================================
// PROCESADORES DE OPERACIONES
// =============================================================================

type OperationProcessor = (payload: Record<string, unknown>) => Promise<void>

const operationProcessors: Record<OperationType, OperationProcessor> = {
  CREATE_PEDIDO: async (payload) => {
    const { data, error } = await supabase.rpc('crear_pedido_completo', payload)
    if (error) throw error
    if (!data?.success) throw new Error(data?.errores?.join(', ') || 'Error al crear pedido')
  },

  UPDATE_PEDIDO: async (payload) => {
    const { id, ...updates } = payload as { id: string; [key: string]: unknown }
    const { error } = await supabase.from('pedidos').update(updates).eq('id', id)
    if (error) throw error
  },

  DELETE_PEDIDO: async (payload) => {
    const { data, error } = await supabase.rpc('eliminar_pedido_completo', payload)
    if (error) throw error
    if (!data?.success) throw new Error(data?.error || 'Error al eliminar pedido')
  },

  CREATE_CLIENTE: async (payload) => {
    const { error } = await supabase.from('clientes').insert(payload)
    if (error) throw error
  },

  UPDATE_CLIENTE: async (payload) => {
    const { id, ...updates } = payload as { id: string; [key: string]: unknown }
    const { error } = await supabase.from('clientes').update(updates).eq('id', id)
    if (error) throw error
  },

  CREATE_MERMA: async (payload) => {
    const { error } = await supabase.from('mermas').insert(payload)
    if (error) throw error
  },

  UPDATE_PRODUCTO: async (payload) => {
    const { id, ...updates } = payload as { id: string; [key: string]: unknown }
    const { error } = await supabase.from('productos').update(updates).eq('id', id)
    if (error) throw error
  },

  SYNC_PAGO: async (payload) => {
    const { error } = await supabase.from('pagos').insert(payload)
    if (error) throw error
  }
}

// =============================================================================
// HOOK PRINCIPAL
// =============================================================================

export function useOfflineQueue(): UseOfflineQueueReturn {
  const [syncState, setSyncState] = useState<SyncState>({
    status: navigator.onLine ? 'online' : 'offline',
    isOnline: navigator.onLine,
    pendingCount: 0,
    failedCount: 0,
    lastSyncAt: null,
    lastError: null
  })

  const isSyncing = useRef(false)
  const syncTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // -------------------------------------------------------------------------
  // Actualizar contadores
  // -------------------------------------------------------------------------
  const updateCounts = useCallback(async () => {
    try {
      const counts = await getOperationCounts()
      setSyncState(prev => ({
        ...prev,
        pendingCount: counts.pending + counts.processing,
        failedCount: counts.failed
      }))
    } catch (err) {
      logger.error('[OfflineQueue] Error actualizando contadores:', err)
    }
  }, [])

  // -------------------------------------------------------------------------
  // Procesar una operación
  // -------------------------------------------------------------------------
  const processOperation = useCallback(async (operation: PendingOperation): Promise<boolean> => {
    const processor = operationProcessors[operation.type]
    if (!processor) {
      logger.error(`[OfflineQueue] No hay procesador para: ${operation.type}`)
      return false
    }

    try {
      await markAsProcessing(operation.id!)
      await processor(operation.payload)
      await markAsCompleted(operation.id!)
      logger.info(`[OfflineQueue] Operación completada: ${operation.type}`)
      return true
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : 'Error desconocido'
      await markAsFailed(operation.id!, errorMessage)
      logger.warn(`[OfflineQueue] Operación fallida: ${operation.type} - ${errorMessage}`)
      return false
    }
  }, [])

  // -------------------------------------------------------------------------
  // Sincronizar operaciones pendientes
  // -------------------------------------------------------------------------
  const syncNow = useCallback(async () => {
    if (isSyncing.current || !navigator.onLine) {
      return
    }

    isSyncing.current = true
    setSyncState(prev => ({ ...prev, status: 'syncing' }))

    try {
      let hasErrors = false
      let processedCount = 0

      // Procesar en lotes de 5
      while (true) {
        const pending = await getPendingOperations(5)
        if (pending.length === 0) break

        for (const operation of pending) {
          const success = await processOperation(operation)
          if (!success) hasErrors = true
          processedCount++

          // Pequeña pausa entre operaciones para no saturar
          await new Promise(resolve => setTimeout(resolve, 100))
        }
      }

      await updateCounts()

      setSyncState(prev => ({
        ...prev,
        status: hasErrors ? 'error' : 'online',
        lastSyncAt: new Date(),
        lastError: hasErrors ? 'Algunas operaciones fallaron' : null
      }))

      if (processedCount > 0) {
        logger.info(`[OfflineQueue] Sincronización completada: ${processedCount} operaciones`)
      }
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : 'Error de sincronización'
      logger.error('[OfflineQueue] Error en sincronización:', err)
      setSyncState(prev => ({
        ...prev,
        status: 'error',
        lastError: errorMessage
      }))
    } finally {
      isSyncing.current = false
    }
  }, [processOperation, updateCounts])

  // -------------------------------------------------------------------------
  // Encolar operación
  // -------------------------------------------------------------------------
  const enqueue = useCallback(async (
    type: OperationType,
    payload: Record<string, unknown>
  ): Promise<number | null> => {
    try {
      // Obtener usuario actual
      const { data: { user } } = await supabase.auth.getUser()

      const id = await queueOperation(type, payload, user?.id)

      if (id !== null) {
        await updateCounts()

        // Si estamos online, intentar sincronizar inmediatamente
        if (navigator.onLine && !isSyncing.current) {
          // Usar timeout para no bloquear
          if (syncTimeoutRef.current) {
            clearTimeout(syncTimeoutRef.current)
          }
          syncTimeoutRef.current = setTimeout(() => syncNow(), 500)
        }
      }

      return id
    } catch (err) {
      logger.error('[OfflineQueue] Error encolando operación:', err)
      return null
    }
  }, [updateCounts, syncNow])

  // -------------------------------------------------------------------------
  // Reintentar operaciones fallidas
  // -------------------------------------------------------------------------
  const retryFailed = useCallback(async () => {
    try {
      // Resetear operaciones fallidas a pendientes
      await db.pendingOperations
        .where('status')
        .equals('failed')
        .modify({ status: 'pending', retryCount: 0 })

      await updateCounts()
      await syncNow()
    } catch (err) {
      logger.error('[OfflineQueue] Error reintentando operaciones:', err)
    }
  }, [updateCounts, syncNow])

  // -------------------------------------------------------------------------
  // Limpiar operaciones antiguas
  // -------------------------------------------------------------------------
  const cleanup = useCallback(async (): Promise<number> => {
    try {
      const deleted = await cleanupOldOperations(7)
      logger.info(`[OfflineQueue] Limpieza: ${deleted} operaciones eliminadas`)
      return deleted
    } catch (err) {
      logger.error('[OfflineQueue] Error en limpieza:', err)
      return 0
    }
  }, [])

  // -------------------------------------------------------------------------
  // Obtener operaciones pendientes
  // -------------------------------------------------------------------------
  const getPending = useCallback(async (): Promise<PendingOperation[]> => {
    return getPendingOperations(100)
  }, [])

  // -------------------------------------------------------------------------
  // Efectos: Listeners de conectividad
  // -------------------------------------------------------------------------
  useEffect(() => {
    const handleOnline = () => {
      logger.info('[OfflineQueue] Conexión restaurada')
      setSyncState(prev => ({ ...prev, isOnline: true, status: 'online' }))
      // Sincronizar después de un pequeño delay
      setTimeout(() => syncNow(), 1000)
    }

    const handleOffline = () => {
      logger.info('[OfflineQueue] Conexión perdida')
      setSyncState(prev => ({ ...prev, isOnline: false, status: 'offline' }))
    }

    window.addEventListener('online', handleOnline)
    window.addEventListener('offline', handleOffline)

    // Cargar estado inicial
    updateCounts()

    // Si hay operaciones pendientes y estamos online, sincronizar
    if (navigator.onLine) {
      setTimeout(() => syncNow(), 2000)
    }

    // Limpieza periódica (cada hora)
    const cleanupInterval = setInterval(() => cleanup(), 60 * 60 * 1000)

    return () => {
      window.removeEventListener('online', handleOnline)
      window.removeEventListener('offline', handleOffline)
      clearInterval(cleanupInterval)
      if (syncTimeoutRef.current) {
        clearTimeout(syncTimeoutRef.current)
      }
    }
  }, [updateCounts, syncNow, cleanup])

  // Sincronizar cuando la app vuelve a estar visible
  useEffect(() => {
    const handleVisibilityChange = () => {
      if (document.visibilityState === 'visible' && navigator.onLine) {
        syncNow()
      }
    }

    document.addEventListener('visibilitychange', handleVisibilityChange)
    return () => document.removeEventListener('visibilitychange', handleVisibilityChange)
  }, [syncNow])

  return {
    syncState,
    enqueue,
    syncNow,
    retryFailed,
    cleanup,
    getPending
  }
}

export default useOfflineQueue

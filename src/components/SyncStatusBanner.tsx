/**
 * SyncStatusBanner - Banner para mostrar estado de sincronización
 *
 * Muestra operaciones fallidas con opciones para reintentar o descartar.
 * Se oculta automáticamente cuando no hay operaciones fallidas.
 */

import { useState, useEffect, useCallback, type ReactElement } from 'react'
import { AlertTriangle, RefreshCw, X, ChevronDown, ChevronUp } from 'lucide-react'
import {
  getOperationCounts,
  getFailedOperations,
  retryAllFailedOperations,
  discardFailedOperations,
  type PendingOperation
} from '../lib/offlineDb'
import { logger } from '../utils/logger'

interface SyncStatusBannerProps {
  /** Callback cuando se reintenta sincronización */
  onRetrySync?: () => void
  /** Intervalo de polling en ms (default: 10000) */
  pollInterval?: number
}

export function SyncStatusBanner({
  onRetrySync,
  pollInterval = 10000
}: SyncStatusBannerProps): ReactElement | null {
  const [failedCount, setFailedCount] = useState(0)
  const [pendingCount, setPendingCount] = useState(0)
  const [failedOps, setFailedOps] = useState<PendingOperation[]>([])
  const [isExpanded, setIsExpanded] = useState(false)
  const [isRetrying, setIsRetrying] = useState(false)
  const [isDismissed, setIsDismissed] = useState(false)

  const fetchStatus = useCallback(async () => {
    try {
      const counts = await getOperationCounts()
      setFailedCount(counts.failed)
      setPendingCount(counts.pending)

      if (counts.failed > 0) {
        const failed = await getFailedOperations(10)
        setFailedOps(failed)
        setIsDismissed(false) // Mostrar si hay nuevos errores
      } else {
        setFailedOps([])
      }
    } catch (error) {
      logger.error('[SyncStatusBanner] Error fetching status:', error)
    }
  }, [])

  useEffect(() => {
    fetchStatus()
    const interval = setInterval(fetchStatus, pollInterval)
    return () => clearInterval(interval)
  }, [fetchStatus, pollInterval])

  const handleRetryAll = async () => {
    setIsRetrying(true)
    try {
      const count = await retryAllFailedOperations()
      logger.info(`[SyncStatusBanner] ${count} operaciones marcadas para reintento`)
      await fetchStatus()
      onRetrySync?.()
    } catch (error) {
      logger.error('[SyncStatusBanner] Error retrying operations:', error)
    } finally {
      setIsRetrying(false)
    }
  }

  const handleDiscardAll = async () => {
    try {
      const count = await discardFailedOperations()
      logger.info(`[SyncStatusBanner] ${count} operaciones descartadas`)
      await fetchStatus()
    } catch (error) {
      logger.error('[SyncStatusBanner] Error discarding operations:', error)
    }
  }

  const handleDismiss = () => {
    setIsDismissed(true)
  }

  // No mostrar si no hay operaciones fallidas o fue descartado
  if (failedCount === 0 || isDismissed) {
    return null
  }

  const getOperationLabel = (type: string): string => {
    const labels: Record<string, string> = {
      CREATE_PEDIDO: 'Crear pedido',
      UPDATE_PEDIDO: 'Actualizar pedido',
      DELETE_PEDIDO: 'Eliminar pedido',
      CREATE_CLIENTE: 'Crear cliente',
      UPDATE_CLIENTE: 'Actualizar cliente',
      CREATE_MERMA: 'Registrar merma',
      UPDATE_PRODUCTO: 'Actualizar producto',
      SYNC_PAGO: 'Sincronizar pago'
    }
    return labels[type] || type
  }

  return (
    <div
      className="fixed bottom-4 left-4 right-4 md:left-auto md:right-4 md:w-96 bg-red-50 dark:bg-red-900/30 border border-red-200 dark:border-red-800 rounded-lg shadow-lg z-40 overflow-hidden"
      role="alert"
      aria-live="polite"
    >
      {/* Header */}
      <div className="flex items-center gap-3 p-4">
        <AlertTriangle className="w-5 h-5 text-red-600 dark:text-red-400 flex-shrink-0" />
        <div className="flex-1 min-w-0">
          <p className="font-medium text-red-800 dark:text-red-200">
            {failedCount} {failedCount === 1 ? 'operación falló' : 'operaciones fallaron'}
          </p>
          {pendingCount > 0 && (
            <p className="text-sm text-red-600 dark:text-red-300">
              {pendingCount} pendientes de sincronizar
            </p>
          )}
        </div>
        <div className="flex items-center gap-1">
          <button
            onClick={() => setIsExpanded(!isExpanded)}
            className="p-1.5 hover:bg-red-100 dark:hover:bg-red-800/50 rounded text-red-600 dark:text-red-400"
            aria-label={isExpanded ? 'Contraer detalles' : 'Expandir detalles'}
          >
            {isExpanded ? <ChevronUp className="w-4 h-4" /> : <ChevronDown className="w-4 h-4" />}
          </button>
          <button
            onClick={handleDismiss}
            className="p-1.5 hover:bg-red-100 dark:hover:bg-red-800/50 rounded text-red-600 dark:text-red-400"
            aria-label="Cerrar banner"
          >
            <X className="w-4 h-4" />
          </button>
        </div>
      </div>

      {/* Detalles expandibles */}
      {isExpanded && failedOps.length > 0 && (
        <div className="px-4 pb-2 border-t border-red-200 dark:border-red-800">
          <ul className="mt-2 space-y-1 max-h-32 overflow-y-auto">
            {failedOps.map((op) => (
              <li
                key={op.id}
                className="text-sm text-red-700 dark:text-red-300 flex justify-between"
              >
                <span>{getOperationLabel(op.type)}</span>
                <span className="text-red-500 dark:text-red-400 text-xs truncate max-w-[150px]">
                  {op.lastError || 'Error desconocido'}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* Acciones */}
      <div className="flex gap-2 p-3 pt-0">
        <button
          onClick={handleRetryAll}
          disabled={isRetrying}
          className="flex-1 flex items-center justify-center gap-2 px-3 py-2 bg-red-600 text-white rounded font-medium text-sm hover:bg-red-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
        >
          <RefreshCw className={`w-4 h-4 ${isRetrying ? 'animate-spin' : ''}`} />
          {isRetrying ? 'Reintentando...' : 'Reintentar'}
        </button>
        <button
          onClick={handleDiscardAll}
          className="px-3 py-2 text-red-700 dark:text-red-300 hover:bg-red-100 dark:hover:bg-red-800/50 rounded text-sm transition-colors"
        >
          Descartar
        </button>
      </div>
    </div>
  )
}

export default SyncStatusBanner

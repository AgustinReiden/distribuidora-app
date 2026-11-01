/**
 * SyncStatusBanner - Banner para mostrar estado de sincronización
 *
 * Muestra operaciones fallidas con opciones para reintentar o descartar.
 * Se oculta automáticamente cuando no hay operaciones fallidas.
 *
 * Todo es de la sesión activa, usuario y sucursal (#1264). IndexedDB es del
 * teléfono, no de la sesión: sin acotar, en un teléfono compartido el usuario
 * B veía el motivo del rechazo de A (que puede nombrar clientes), y
 * "Reintentar" o "Eliminar" actuaban sobre los pedidos de A.
 */

import { useState, useEffect, useCallback, type ReactElement } from 'react'
import { createPortal } from 'react-dom'
import { AlertTriangle, RefreshCw, X, ChevronDown, ChevronUp } from 'lucide-react'
import {
  getOperationCounts,
  getFailedOperations,
  getMaxFailedOperationId,
  retryAllFailedOperations,
  discardFailedOperations,
  reintentarSinRegalos,
  reintentarSinCombos,
  type PendingOperation
} from '../lib/offlineDb'
import { useSucursal } from '../contexts/SucursalContext'
import { logger } from '../utils/logger'
import { Button } from './ui/Button'
import { getNoticeRoot } from './ui/noticeRoot'
import ModalConfirmacion from './modals/ModalConfirmacion'

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
  // Id más alto entre TODAS las fallidas de la sesión, no sólo entre las 10 que
  // se listan: `failedOps` trae los ids más bajos, y con más de diez la fallida
  // nueva no entraba en la muestra ni reabría el banner cerrado (PLT-N6, #1305).
  const [maxIdActual, setMaxIdActual] = useState(0)
  const [isExpanded, setIsExpanded] = useState(false)
  const [isRetrying, setIsRetrying] = useState(false)
  // Id más alto entre las fallidas que la usuaria ya cerró (con la X o con
  // "Descartar"). Antes el cierre era un booleano (`isDismissed`) que cada
  // poll de 10s volvía a pisar en `false` apenas `counts.failed > 0` -- que
  // seguía siendo cierto para las MISMAS fallidas que se acababan de cerrar --
  // así que el banner rojo no se podía cerrar de verdad y empujaba a
  // "Descartar" (que borra los pedidos) para sacárselo de encima. Guardando el
  // id máximo en vez de un booleano, el banner se queda cerrado hasta que
  // aparece una fallida realmente nueva.
  const [descartadoHastaId, setDescartadoHastaId] = useState(0)
  // "Eliminar" borra pedidos que no se van a sincronizar: pide confirmación.
  const [confirmandoEliminar, setConfirmandoEliminar] = useState(false)

  const { userId, currentSucursalId } = useSucursal()

  const fetchStatus = useCallback(async () => {
    // Sin sesión no hay de quién mostrar nada (y sin dueño, el filtro dejaría
    // pasar las de todos).
    if (!userId) {
      setFailedCount(0)
      setPendingCount(0)
      setFailedOps([])
      setMaxIdActual(0)
      return
    }
    try {
      const counts = await getOperationCounts(userId, currentSucursalId)
      setFailedCount(counts.failed)
      setPendingCount(counts.pending)

      if (counts.failed > 0) {
        const [failed, maxId] = await Promise.all([
          getFailedOperations(10, userId, currentSucursalId),
          getMaxFailedOperationId(userId, currentSucursalId)
        ])
        setFailedOps(failed)
        setMaxIdActual(maxId)
      } else {
        setFailedOps([])
        setMaxIdActual(0)
      }
    } catch (error) {
      logger.error('[SyncStatusBanner] Error fetching status:', error)
    }
  }, [userId, currentSucursalId])

  useEffect(() => {
    fetchStatus()
    const interval = setInterval(fetchStatus, pollInterval)
    return () => clearInterval(interval)
  }, [fetchStatus, pollInterval])

  const handleRetryAll = async () => {
    if (!userId) return
    setIsRetrying(true)
    try {
      const count = await retryAllFailedOperations(userId, currentSucursalId)
      logger.info(`[SyncStatusBanner] ${count} operaciones marcadas para reintento`)
      await fetchStatus()
      onRetrySync?.()
    } catch (error) {
      logger.error('[SyncStatusBanner] Error retrying operations:', error)
    } finally {
      setIsRetrying(false)
    }
  }

  // #1153: el preventista decide mandar el pedido sin el regalo que dejó de
  // ser legal. Por operación: es una decisión comercial, no un reintento.
  const handleSinRegalo = async (id: number) => {
    try {
      await reintentarSinRegalos(id)
      await fetchStatus()
      onRetrySync?.()
    } catch (error) {
      logger.error('[SyncStatusBanner] Error reintentando sin el regalo:', error)
    }
  }

  // #1191: idem para un combo que dejó de ser legal (tope, vigencia).
  const handleSinCombos = async (id: number) => {
    try {
      await reintentarSinCombos(id)
      await fetchStatus()
      onRetrySync?.()
    } catch (error) {
      logger.error('[SyncStatusBanner] Error reintentando sin los combos:', error)
    }
  }

  // Borra de verdad, así que deja rastro: `discardFailedOperations` guarda cada
  // operación entera en `syncEvents` antes de borrarla.
  const handleDiscardAll = async () => {
    setConfirmandoEliminar(false)
    if (!userId) return
    try {
      const count = await discardFailedOperations(userId, currentSucursalId)
      logger.warn(`[SyncStatusBanner] ${count} operaciones fallidas eliminadas a mano`)
      await fetchStatus()
    } catch (error) {
      logger.error('[SyncStatusBanner] Error discarding operations:', error)
    }
  }

  const handleDismiss = () => {
    setDescartadoHastaId(maxIdActual)
  }

  // No mostrar si no hay operaciones fallidas o si ya se cerró y no apareció
  // ninguna fallida nueva desde entonces.
  if (failedCount === 0 || maxIdActual <= descartadoHastaId) {
    return null
  }

  const getOperationLabel = (type: string): string => {
    const labels: Record<string, string> = {
      CREATE_PEDIDO: 'Crear pedido',
      UPDATE_PEDIDO: 'Actualizar pedido',
      DELETE_PEDIDO: 'Eliminar pedido',
      CREATE_CLIENTE: 'Crear cliente',
      UPDATE_CLIENTE: 'Actualizar cliente',
      UPDATE_PRODUCTO: 'Actualizar producto',
      SYNC_PAGO: 'Sincronizar pago'
    }
    return labels[type] || type
  }

  // La posición la pone la pila de avisos (ver ui/noticeRoot), no este wrapper.
  const root = getNoticeRoot()
  const aviso = (
    <div
      className="pointer-events-auto w-full max-w-sm md:w-96 bg-red-50 dark:bg-red-900/30 border border-red-200 dark:border-red-800 rounded-lg shadow-lg overflow-hidden"
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
          <Button
            variant="ghost"
            size="iconSm"
            onClick={() => setIsExpanded(!isExpanded)}
            className="text-red-600 dark:text-red-400 hover:bg-red-100 dark:hover:bg-red-800/50"
            aria-label={isExpanded ? 'Contraer detalles' : 'Expandir detalles'}
          >
            {isExpanded ? <ChevronUp className="w-4 h-4" /> : <ChevronDown className="w-4 h-4" />}
          </Button>
          <Button
            variant="ghost"
            size="iconSm"
            onClick={handleDismiss}
            className="text-red-600 dark:text-red-400 hover:bg-red-100 dark:hover:bg-red-800/50"
            aria-label="Cerrar banner"
          >
            <X className="w-4 h-4" />
          </Button>
        </div>
      </div>

      {/* Detalles expandibles */}
      {isExpanded && failedOps.length > 0 && (
        <div className="px-4 pb-2 border-t border-red-200 dark:border-red-800">
          {/* El motivo va DEBAJO y entero: es lo único que le dice al preventista
              qué hacer. Truncado a 150px, un rechazo como "Cliente asignado a otro
              preventista: X (#N) lo atiende Y" se leía "Cliente asignado a…" y
              terminaba en un llamado a la oficina. */}
          <ul className="mt-2 space-y-2 max-h-40 overflow-y-auto">
            {failedOps.map((op) => (
              <li
                key={op.id}
                className="text-sm text-red-700 dark:text-red-300"
              >
                <span className="font-medium">{getOperationLabel(op.type)}</span>
                <p className="text-red-500 dark:text-red-400 text-xs break-words">
                  {op.lastError || 'Error desconocido'}
                </p>
                {op.rechazoRegalo && op.id != null && (
                  <Button
                    variant="secondary"
                    size="sm"
                    onClick={() => { void handleSinRegalo(op.id!) }}
                    className="mt-1"
                    title="Quita las líneas de regalo de este pedido y lo vuelve a mandar. Avisale al cliente."
                  >
                    Sincronizar sin el regalo
                  </Button>
                )}
                {op.rechazoCombo && op.id != null && (
                  <Button
                    variant="secondary"
                    size="sm"
                    onClick={() => { void handleSinCombos(op.id!) }}
                    className="mt-1"
                    title="Pasa las líneas de combo de este pedido a su precio sin combo y lo vuelve a mandar. El total sube: avisale al cliente."
                  >
                    Sincronizar sin los combos
                  </Button>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* Acciones */}
      <div className="flex gap-2 p-3 pt-0">
        <Button
          variant="danger"
          onClick={handleRetryAll}
          disabled={isRetrying}
          className="flex-1"
        >
          <RefreshCw className={`w-4 h-4 ${isRetrying ? 'animate-spin' : ''}`} />
          {isRetrying ? 'Reintentando...' : 'Reintentar'}
        </Button>
        <Button
          variant="ghost"
          onClick={() => setConfirmandoEliminar(true)}
          className="text-red-700 dark:text-red-300 hover:bg-red-100 dark:hover:bg-red-800/50"
          title="Elimina estas operaciones; no se van a sincronizar"
        >
          Eliminar
        </Button>
      </div>
    </div>
  )

  return (
    <>
      {root ? createPortal(aviso, root) : aviso}
      <ModalConfirmacion
        config={confirmandoEliminar ? {
          visible: true,
          tipo: 'danger',
          titulo: failedCount === 1 ? '¿Eliminar la operación fallida?' : `¿Eliminar las ${failedCount} operaciones fallidas?`,
          mensaje: `${failedCount === 1 ? 'Se borra de este teléfono y no se va' : 'Se borran de este teléfono y no se van'} a sincronizar. Si es un pedido, no va a llegar al sistema.`,
          onConfirm: () => { void handleDiscardAll() },
        } : null}
        onClose={() => setConfirmandoEliminar(false)}
      />
    </>
  )
}

export default SyncStatusBanner

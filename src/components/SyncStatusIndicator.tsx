/**
 * SyncStatusIndicator - Indicador visual del estado de sincronización
 *
 * Muestra el estado de conexión y operaciones pendientes:
 * - 🟢 Online (Sincronizado)
 * - 🟡 Offline (Guardando local)
 * - 🔵 Sincronizando...
 * - 🔴 Error (Requiere acción)
 */

import React, { useState, useCallback } from 'react'
import {
  Wifi,
  WifiOff,
  CloudOff,
  Cloud,
  RefreshCw,
  AlertCircle,
  CheckCircle,
  ChevronDown,
  ChevronUp,
  Trash2
} from 'lucide-react'
import { useOfflineQueue, type SyncStatus } from '../hooks/useOfflineQueue'

// =============================================================================
// CONFIGURACIÓN DE ESTADOS
// =============================================================================

interface StatusConfig {
  icon: React.ReactNode
  bgColor: string
  textColor: string
  pulseColor: string
  label: string
  description: string
}

const statusConfig: Record<SyncStatus, StatusConfig> = {
  online: {
    icon: <Cloud className="w-4 h-4" />,
    bgColor: 'bg-green-100 dark:bg-green-900/30',
    textColor: 'text-green-700 dark:text-green-400',
    pulseColor: 'bg-green-500',
    label: 'Sincronizado',
    description: 'Todos los datos están actualizados'
  },
  offline: {
    icon: <CloudOff className="w-4 h-4" />,
    bgColor: 'bg-yellow-100 dark:bg-yellow-900/30',
    textColor: 'text-yellow-700 dark:text-yellow-400',
    pulseColor: 'bg-yellow-500',
    label: 'Offline',
    description: 'Guardando cambios localmente'
  },
  syncing: {
    icon: <RefreshCw className="w-4 h-4 animate-spin" />,
    bgColor: 'bg-blue-100 dark:bg-blue-900/30',
    textColor: 'text-blue-700 dark:text-blue-400',
    pulseColor: 'bg-blue-500',
    label: 'Sincronizando',
    description: 'Enviando cambios al servidor...'
  },
  error: {
    icon: <AlertCircle className="w-4 h-4" />,
    bgColor: 'bg-red-100 dark:bg-red-900/30',
    textColor: 'text-red-700 dark:text-red-400',
    pulseColor: 'bg-red-500',
    label: 'Error',
    description: 'Algunas operaciones fallaron'
  }
}

// =============================================================================
// COMPONENTE PRINCIPAL
// =============================================================================

export interface SyncStatusIndicatorProps {
  /** Mostrar versión compacta (solo ícono) */
  compact?: boolean
  /** Mostrar en el header */
  className?: string
}

export function SyncStatusIndicator({ compact = false, className = '' }: SyncStatusIndicatorProps) {
  const { syncState, syncNow, retryFailed, cleanup, getPending } = useOfflineQueue()
  const [expanded, setExpanded] = useState(false)
  const [pendingDetails, setPendingDetails] = useState<Array<{ type: string; createdAt: Date }>>([])

  const config = statusConfig[syncState.status]

  // Cargar detalles de operaciones pendientes
  const loadPendingDetails = useCallback(async () => {
    const pending = await getPending()
    setPendingDetails(pending.map(p => ({ type: p.type, createdAt: p.createdAt })))
  }, [getPending])

  // Toggle expandir
  const handleToggle = useCallback(() => {
    if (!expanded) {
      loadPendingDetails()
    }
    setExpanded(!expanded)
  }, [expanded, loadPendingDetails])

  // Versión compacta (solo indicador de punto)
  if (compact) {
    return (
      <div className={`relative flex items-center ${className}`} title={config.label}>
        <div className={`w-2 h-2 rounded-full ${config.pulseColor}`}>
          {syncState.status === 'syncing' && (
            <div className={`absolute inset-0 w-2 h-2 rounded-full ${config.pulseColor} animate-ping`} />
          )}
        </div>
        {syncState.pendingCount > 0 && (
          <span className="ml-1 text-xs text-gray-500">{syncState.pendingCount}</span>
        )}
      </div>
    )
  }

  return (
    <div className={`relative ${className}`}>
      {/* Botón principal */}
      <button
        onClick={handleToggle}
        className={`
          flex items-center gap-2 px-3 py-1.5 rounded-lg
          ${config.bgColor} ${config.textColor}
          transition-all duration-200
          hover:opacity-80 focus:outline-none focus:ring-2 focus:ring-offset-2
        `}
      >
        {/* Indicador de estado */}
        <div className="relative">
          <div className={`w-2 h-2 rounded-full ${config.pulseColor}`} />
          {syncState.status === 'syncing' && (
            <div className={`absolute inset-0 w-2 h-2 rounded-full ${config.pulseColor} animate-ping`} />
          )}
        </div>

        {/* Ícono */}
        {config.icon}

        {/* Texto */}
        <span className="text-sm font-medium">{config.label}</span>

        {/* Badge de pendientes */}
        {syncState.pendingCount > 0 && (
          <span className={`
            px-1.5 py-0.5 text-xs font-bold rounded-full
            ${syncState.status === 'error' ? 'bg-red-200 text-red-800' : 'bg-gray-200 text-gray-800'}
          `}>
            {syncState.pendingCount}
          </span>
        )}

        {/* Flecha expandir */}
        {expanded ? (
          <ChevronUp className="w-4 h-4" />
        ) : (
          <ChevronDown className="w-4 h-4" />
        )}
      </button>

      {/* Panel expandido */}
      {expanded && (
        <div className="absolute top-full right-0 mt-2 w-80 bg-white dark:bg-gray-800 rounded-xl shadow-xl border dark:border-gray-700 z-50 overflow-hidden">
          {/* Header del panel */}
          <div className={`px-4 py-3 ${config.bgColor} border-b dark:border-gray-700`}>
            <div className="flex items-center gap-2">
              {syncState.isOnline ? (
                <Wifi className={`w-5 h-5 ${config.textColor}`} />
              ) : (
                <WifiOff className={`w-5 h-5 ${config.textColor}`} />
              )}
              <div>
                <p className={`font-medium ${config.textColor}`}>{config.label}</p>
                <p className="text-xs text-gray-500 dark:text-gray-400">{config.description}</p>
              </div>
            </div>
          </div>

          {/* Estadísticas */}
          <div className="px-4 py-3 border-b dark:border-gray-700">
            <div className="grid grid-cols-2 gap-3 text-sm">
              <div className="flex items-center gap-2">
                <RefreshCw className="w-4 h-4 text-blue-500" />
                <span className="text-gray-600 dark:text-gray-400">Pendientes:</span>
                <span className="font-medium">{syncState.pendingCount}</span>
              </div>
              <div className="flex items-center gap-2">
                <AlertCircle className="w-4 h-4 text-red-500" />
                <span className="text-gray-600 dark:text-gray-400">Fallidos:</span>
                <span className="font-medium">{syncState.failedCount}</span>
              </div>
            </div>

            {syncState.lastSyncAt && (
              <p className="text-xs text-gray-500 mt-2">
                Última sync: {syncState.lastSyncAt.toLocaleTimeString()}
              </p>
            )}

            {syncState.lastError && (
              <p className="text-xs text-red-500 mt-1">
                Error: {syncState.lastError}
              </p>
            )}
          </div>

          {/* Lista de operaciones pendientes */}
          {pendingDetails.length > 0 && (
            <div className="px-4 py-2 max-h-40 overflow-y-auto border-b dark:border-gray-700">
              <p className="text-xs font-medium text-gray-500 mb-2">Operaciones pendientes:</p>
              <ul className="space-y-1">
                {pendingDetails.slice(0, 5).map((op, i) => (
                  <li key={i} className="flex items-center justify-between text-xs">
                    <span className="text-gray-700 dark:text-gray-300">{op.type}</span>
                    <span className="text-gray-400">
                      {op.createdAt.toLocaleTimeString()}
                    </span>
                  </li>
                ))}
                {pendingDetails.length > 5 && (
                  <li className="text-xs text-gray-400">
                    +{pendingDetails.length - 5} más...
                  </li>
                )}
              </ul>
            </div>
          )}

          {/* Acciones */}
          <div className="px-4 py-3 flex gap-2">
            <button
              onClick={() => syncNow()}
              disabled={!syncState.isOnline || syncState.status === 'syncing'}
              className="flex-1 flex items-center justify-center gap-2 px-3 py-2 bg-blue-600 hover:bg-blue-700 disabled:bg-gray-400 text-white text-sm font-medium rounded-lg transition-colors"
            >
              <RefreshCw className={`w-4 h-4 ${syncState.status === 'syncing' ? 'animate-spin' : ''}`} />
              Sincronizar
            </button>

            {syncState.failedCount > 0 && (
              <button
                onClick={() => retryFailed()}
                disabled={!syncState.isOnline}
                className="flex items-center justify-center gap-2 px-3 py-2 bg-yellow-600 hover:bg-yellow-700 disabled:bg-gray-400 text-white text-sm font-medium rounded-lg transition-colors"
                title="Reintentar fallidos"
              >
                <RefreshCw className="w-4 h-4" />
              </button>
            )}

            <button
              onClick={async () => {
                await cleanup()
                loadPendingDetails()
              }}
              className="flex items-center justify-center gap-2 px-3 py-2 bg-gray-200 hover:bg-gray-300 dark:bg-gray-700 dark:hover:bg-gray-600 text-gray-700 dark:text-gray-300 text-sm font-medium rounded-lg transition-colors"
              title="Limpiar completados"
            >
              <Trash2 className="w-4 h-4" />
            </button>
          </div>

          {/* Estado de conexión */}
          <div className={`px-4 py-2 text-center text-xs ${syncState.isOnline ? 'bg-green-50 dark:bg-green-900/20 text-green-600' : 'bg-yellow-50 dark:bg-yellow-900/20 text-yellow-600'}`}>
            <div className="flex items-center justify-center gap-2">
              {syncState.isOnline ? (
                <>
                  <CheckCircle className="w-3 h-3" />
                  <span>Conectado a internet</span>
                </>
              ) : (
                <>
                  <WifiOff className="w-3 h-3" />
                  <span>Sin conexión - Los cambios se guardan localmente</span>
                </>
              )}
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

// =============================================================================
// COMPONENTE MINIMALISTA PARA HEADER
// =============================================================================

export function SyncStatusBadge() {
  const { syncState, syncNow } = useOfflineQueue()
  const config = statusConfig[syncState.status]

  return (
    <button
      onClick={() => {
        if (syncState.isOnline && syncState.status !== 'syncing') {
          syncNow()
        }
      }}
      className={`
        flex items-center gap-1.5 px-2 py-1 rounded-md
        ${config.bgColor} ${config.textColor}
        transition-all duration-200 hover:opacity-80
      `}
      title={`${config.label}: ${config.description}`}
    >
      <div className="relative">
        <div className={`w-1.5 h-1.5 rounded-full ${config.pulseColor}`} />
        {syncState.status === 'syncing' && (
          <div className={`absolute inset-0 w-1.5 h-1.5 rounded-full ${config.pulseColor} animate-ping`} />
        )}
      </div>
      {syncState.pendingCount > 0 && (
        <span className="text-xs font-medium">{syncState.pendingCount}</span>
      )}
    </button>
  )
}

export default SyncStatusIndicator

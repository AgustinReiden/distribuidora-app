/**
 * SavedRoutesPanel - Panel para ver y gestionar rutas guardadas
 *
 * Permite:
 * - Ver rutas guardadas del transportista
 * - Cargar una ruta guardada
 * - Eliminar rutas antiguas
 */

import React, { useState } from 'react'
import {
  Map,
  Clock,
  Route as RouteIcon,
  Trash2,
  ChevronRight,
  Save,
  Star,
  AlertCircle
} from 'lucide-react'
import { useSavedRoutes, formatDuration, formatDistance, type RouteToSave } from '../hooks/useSavedRoutes'
import type { SavedRoute } from '../lib/offlineDb'

// =============================================================================
// TIPOS
// =============================================================================

export interface SavedRoutesPanelProps {
  transportistaId: string | null
  onLoadRoute?: (route: SavedRoute) => void
  currentClienteIds?: string[]
  onSaveCurrentRoute?: (nombre: string, descripcion?: string) => void
  className?: string
}

// =============================================================================
// COMPONENTE PRINCIPAL
// =============================================================================

export function SavedRoutesPanel({
  transportistaId,
  onLoadRoute,
  currentClienteIds = [],
  onSaveCurrentRoute,
  className = ''
}: SavedRoutesPanelProps) {
  const {
    routes,
    loading,
    findExistingRoute,
    deleteRoute
  } = useSavedRoutes(transportistaId)

  const [showSaveForm, setShowSaveForm] = useState(false)
  const [routeName, setRouteName] = useState('')
  const [routeDescription, setRouteDescription] = useState('')
  const [savingRoute, setSavingRoute] = useState(false)
  const [matchingRoute, setMatchingRoute] = useState<SavedRoute | null>(null)

  // Buscar ruta existente cuando cambian los clientes
  React.useEffect(() => {
    if (currentClienteIds.length > 0) {
      findExistingRoute(currentClienteIds).then(setMatchingRoute)
    } else {
      setMatchingRoute(null)
    }
  }, [currentClienteIds, findExistingRoute])

  // Guardar ruta actual
  const handleSaveRoute = async () => {
    if (!routeName.trim() || !onSaveCurrentRoute) return

    setSavingRoute(true)
    try {
      await onSaveCurrentRoute(routeName.trim(), routeDescription.trim() || undefined)
      setShowSaveForm(false)
      setRouteName('')
      setRouteDescription('')
    } finally {
      setSavingRoute(false)
    }
  }

  // Eliminar ruta con confirmación
  const handleDeleteRoute = async (route: SavedRoute) => {
    if (!confirm(`¿Eliminar la ruta "${route.nombre}"?`)) return
    await deleteRoute(route.id!)
  }

  if (!transportistaId) {
    return (
      <div className={`p-4 text-center text-gray-500 ${className}`}>
        Selecciona un transportista para ver sus rutas guardadas
      </div>
    )
  }

  return (
    <div className={`${className}`}>
      {/* Sugerencia de ruta existente */}
      {matchingRoute && (
        <div className="mb-4 p-3 bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg">
          <div className="flex items-start gap-3">
            <Star className="w-5 h-5 text-blue-600 flex-shrink-0 mt-0.5" />
            <div className="flex-1">
              <p className="text-sm font-medium text-blue-800 dark:text-blue-300">
                Ruta similar encontrada
              </p>
              <p className="text-xs text-blue-600 dark:text-blue-400 mt-1">
                "{matchingRoute.nombre}" tiene los mismos clientes.
                ¿Deseas usarla para ahorrar tiempo?
              </p>
              <button
                onClick={() => onLoadRoute?.(matchingRoute)}
                className="mt-2 flex items-center gap-1 text-sm text-blue-700 dark:text-blue-400 hover:underline"
              >
                <RouteIcon className="w-4 h-4" />
                Usar esta ruta
                <ChevronRight className="w-4 h-4" />
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Header con botón de guardar */}
      <div className="flex items-center justify-between mb-3">
        <h3 className="text-sm font-semibold text-gray-700 dark:text-gray-300 flex items-center gap-2">
          <Map className="w-4 h-4" />
          Rutas Guardadas
        </h3>

        {onSaveCurrentRoute && currentClienteIds.length > 0 && !showSaveForm && (
          <button
            onClick={() => setShowSaveForm(true)}
            className="flex items-center gap-1 text-xs text-blue-600 hover:text-blue-700"
          >
            <Save className="w-3 h-3" />
            Guardar actual
          </button>
        )}
      </div>

      {/* Formulario de guardar */}
      {showSaveForm && (
        <div className="mb-4 p-3 bg-gray-50 dark:bg-gray-800 rounded-lg border dark:border-gray-700">
          <input
            type="text"
            value={routeName}
            onChange={(e) => setRouteName(e.target.value)}
            placeholder="Nombre de la ruta (ej: Lunes Zona Norte)"
            className="w-full px-3 py-2 text-sm border rounded-lg dark:bg-gray-700 dark:border-gray-600 mb-2"
            autoFocus
          />
          <input
            type="text"
            value={routeDescription}
            onChange={(e) => setRouteDescription(e.target.value)}
            placeholder="Descripción (opcional)"
            className="w-full px-3 py-2 text-sm border rounded-lg dark:bg-gray-700 dark:border-gray-600 mb-2"
          />
          <div className="flex gap-2">
            <button
              onClick={handleSaveRoute}
              disabled={!routeName.trim() || savingRoute}
              className="flex-1 px-3 py-1.5 bg-blue-600 hover:bg-blue-700 disabled:bg-gray-400 text-white text-sm rounded-lg"
            >
              {savingRoute ? 'Guardando...' : 'Guardar'}
            </button>
            <button
              onClick={() => setShowSaveForm(false)}
              className="px-3 py-1.5 bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-300 text-sm rounded-lg"
            >
              Cancelar
            </button>
          </div>
        </div>
      )}

      {/* Lista de rutas */}
      {loading ? (
        <div className="py-8 text-center text-gray-500">
          <div className="animate-spin w-6 h-6 border-2 border-gray-300 border-t-blue-600 rounded-full mx-auto mb-2" />
          Cargando rutas...
        </div>
      ) : routes.length === 0 ? (
        <div className="py-6 text-center text-gray-500">
          <Map className="w-8 h-8 mx-auto mb-2 opacity-50" />
          <p className="text-sm">No hay rutas guardadas</p>
          <p className="text-xs mt-1">
            Optimiza una ruta y guárdala para reutilizarla
          </p>
        </div>
      ) : (
        <div className="space-y-2 max-h-64 overflow-y-auto">
          {routes.map((route) => (
            <div
              key={route.id}
              className="p-3 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg hover:border-blue-300 transition-colors group"
            >
              <div className="flex items-start justify-between">
                <div
                  className="flex-1 cursor-pointer"
                  onClick={() => onLoadRoute?.(route)}
                >
                  <p className="font-medium text-sm text-gray-800 dark:text-gray-200">
                    {route.nombre}
                  </p>
                  {route.descripcion && (
                    <p className="text-xs text-gray-500 mt-0.5">{route.descripcion}</p>
                  )}
                  <div className="flex items-center gap-3 mt-2 text-xs text-gray-500">
                    <span className="flex items-center gap-1">
                      <RouteIcon className="w-3 h-3" />
                      {route.clienteIds.length} clientes
                    </span>
                    {route.distanciaTotal && (
                      <span>{formatDistance(route.distanciaTotal)}</span>
                    )}
                    {route.duracionEstimada && (
                      <span className="flex items-center gap-1">
                        <Clock className="w-3 h-3" />
                        {formatDuration(route.duracionEstimada)}
                      </span>
                    )}
                  </div>
                  {route.lastUsedAt && (
                    <p className="text-xs text-gray-400 mt-1">
                      Última vez: {route.lastUsedAt.toLocaleDateString()}
                    </p>
                  )}
                </div>

                <button
                  onClick={() => handleDeleteRoute(route)}
                  className="p-1.5 text-gray-400 hover:text-red-500 opacity-0 group-hover:opacity-100 transition-opacity"
                  title="Eliminar ruta"
                >
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Nota informativa */}
      <div className="mt-3 p-2 bg-yellow-50 dark:bg-yellow-900/20 rounded text-xs text-yellow-700 dark:text-yellow-400 flex items-start gap-2">
        <AlertCircle className="w-4 h-4 flex-shrink-0 mt-0.5" />
        <span>
          Las rutas guardadas evitan llamadas repetidas a Google Maps, ahorrando costos.
        </span>
      </div>
    </div>
  )
}

export default SavedRoutesPanel

/**
 * useSavedRoutes - Hook para guardar y reutilizar rutas optimizadas
 *
 * Beneficios:
 * - Ahorra llamadas a Google Maps API ($5/1000 requests)
 * - Rutas recurrentes se cargan instantáneamente
 * - Funciona offline
 */

import { useState, useEffect, useCallback } from 'react'
import {
  saveOptimizedRoute,
  getSavedRoutes,
  findMatchingRoute,
  markRouteAsUsed,
  updateSavedRoute,
  deleteSavedRoute,
  type SavedRoute
} from '../lib/offlineDb'
import { logger } from '../utils/logger'

// =============================================================================
// TIPOS
// =============================================================================

export interface RouteToSave {
  nombre: string
  descripcion?: string
  clienteIds: string[]
  ordenOptimizado: number[]
  polylineEncoded?: string
  distanciaTotal?: number
  duracionEstimada?: number
}

export interface UseSavedRoutesReturn {
  /** Rutas guardadas del transportista actual */
  routes: SavedRoute[]
  /** Está cargando */
  loading: boolean
  /** Buscar ruta similar existente */
  findExistingRoute: (clienteIds: string[]) => Promise<SavedRoute | null>
  /** Guardar nueva ruta */
  saveRoute: (route: RouteToSave) => Promise<number>
  /** Actualizar ruta existente */
  updateRoute: (routeId: number, updates: Partial<RouteToSave>) => Promise<void>
  /** Eliminar ruta */
  deleteRoute: (routeId: number) => Promise<void>
  /** Marcar ruta como usada (actualiza lastUsedAt) */
  useRoute: (routeId: number) => Promise<void>
  /** Recargar rutas */
  refresh: () => Promise<void>
}

// =============================================================================
// HOOK PRINCIPAL
// =============================================================================

export function useSavedRoutes(transportistaId: string | null): UseSavedRoutesReturn {
  const [routes, setRoutes] = useState<SavedRoute[]>([])
  const [loading, setLoading] = useState(true)

  // -------------------------------------------------------------------------
  // Cargar rutas del transportista
  // -------------------------------------------------------------------------
  const loadRoutes = useCallback(async () => {
    if (!transportistaId) {
      setRoutes([])
      setLoading(false)
      return
    }

    setLoading(true)
    try {
      const savedRoutes = await getSavedRoutes(transportistaId)
      setRoutes(savedRoutes)
    } catch (err) {
      logger.error('[SavedRoutes] Error cargando rutas:', err)
    } finally {
      setLoading(false)
    }
  }, [transportistaId])

  // Cargar al montar o cambiar transportista
  useEffect(() => {
    loadRoutes()
  }, [loadRoutes])

  // -------------------------------------------------------------------------
  // Buscar ruta existente similar
  // -------------------------------------------------------------------------
  const findExistingRoute = useCallback(async (clienteIds: string[]): Promise<SavedRoute | null> => {
    if (!transportistaId || clienteIds.length === 0) return null

    try {
      // Buscar ruta con al menos 80% de similitud
      const matchingRoute = await findMatchingRoute(transportistaId, clienteIds, 20)

      if (matchingRoute) {
        logger.info(`[SavedRoutes] Ruta existente encontrada: ${matchingRoute.nombre}`)
      }

      return matchingRoute
    } catch (err) {
      logger.error('[SavedRoutes] Error buscando ruta:', err)
      return null
    }
  }, [transportistaId])

  // -------------------------------------------------------------------------
  // Guardar nueva ruta
  // -------------------------------------------------------------------------
  const saveRoute = useCallback(async (route: RouteToSave): Promise<number> => {
    if (!transportistaId) {
      throw new Error('No hay transportista seleccionado')
    }

    try {
      const id = await saveOptimizedRoute({
        ...route,
        transportistaId
      })

      logger.info(`[SavedRoutes] Ruta guardada: ${route.nombre}`)

      // Recargar lista
      await loadRoutes()

      return id
    } catch (err) {
      logger.error('[SavedRoutes] Error guardando ruta:', err)
      throw err
    }
  }, [transportistaId, loadRoutes])

  // -------------------------------------------------------------------------
  // Actualizar ruta
  // -------------------------------------------------------------------------
  const updateRoute = useCallback(async (
    routeId: number,
    updates: Partial<RouteToSave>
  ): Promise<void> => {
    try {
      await updateSavedRoute(routeId, updates)
      logger.info(`[SavedRoutes] Ruta actualizada: ${routeId}`)
      await loadRoutes()
    } catch (err) {
      logger.error('[SavedRoutes] Error actualizando ruta:', err)
      throw err
    }
  }, [loadRoutes])

  // -------------------------------------------------------------------------
  // Eliminar ruta
  // -------------------------------------------------------------------------
  const deleteRoute = useCallback(async (routeId: number): Promise<void> => {
    try {
      await deleteSavedRoute(routeId)
      logger.info(`[SavedRoutes] Ruta eliminada: ${routeId}`)
      await loadRoutes()
    } catch (err) {
      logger.error('[SavedRoutes] Error eliminando ruta:', err)
      throw err
    }
  }, [loadRoutes])

  // -------------------------------------------------------------------------
  // Marcar ruta como usada
  // -------------------------------------------------------------------------
  const useRoute = useCallback(async (routeId: number): Promise<void> => {
    try {
      await markRouteAsUsed(routeId)
      // No recargar toda la lista, solo actualizar localmente
      setRoutes(prev => prev.map(r =>
        r.id === routeId
          ? { ...r, lastUsedAt: new Date(), updatedAt: new Date() }
          : r
      ))
    } catch (err) {
      logger.error('[SavedRoutes] Error marcando ruta como usada:', err)
    }
  }, [])

  return {
    routes,
    loading,
    findExistingRoute,
    saveRoute,
    updateRoute,
    deleteRoute,
    useRoute,
    refresh: loadRoutes
  }
}

// =============================================================================
// UTILIDADES
// =============================================================================

/**
 * Calcula el porcentaje de similitud entre dos arrays de IDs
 */
export function calculateRouteSimilarity(route1: string[], route2: string[]): number {
  const set1 = new Set(route1)
  const set2 = new Set(route2)

  const intersection = new Set([...set1].filter(x => set2.has(x)))
  const union = new Set([...set1, ...set2])

  return (intersection.size / union.size) * 100
}

/**
 * Formatea la duración en formato legible
 */
export function formatDuration(seconds: number): string {
  const hours = Math.floor(seconds / 3600)
  const minutes = Math.floor((seconds % 3600) / 60)

  if (hours > 0) {
    return `${hours}h ${minutes}m`
  }
  return `${minutes} min`
}

/**
 * Formatea la distancia en formato legible
 */
export function formatDistance(meters: number): string {
  if (meters >= 1000) {
    return `${(meters / 1000).toFixed(1)} km`
  }
  return `${meters} m`
}

export default useSavedRoutes

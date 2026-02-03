/**
 * Hook para cargar Google Maps API dinamicamente
 *
 * Ventajas sobre carga estatica en index.html:
 * - API key en variable de entorno (no expuesta en HTML)
 * - Carga bajo demanda (mejor performance inicial)
 * - Mejor manejo de errores
 */

import { useState, useCallback, useEffect } from 'react'
import { logger } from '../utils/logger'

/**
 * ID del script de Google Maps en el DOM
 */
const GOOGLE_MAPS_SCRIPT_ID = 'google-maps-script'

/**
 * Promesa de carga compartida para evitar cargas duplicadas
 */
let loadPromise: Promise<void> | null = null

/**
 * Verifica si la API de Google Maps Places está disponible
 */
function isGoogleMapsLoaded(): boolean {
  return !!(window.google?.maps?.places?.AutocompleteService)
}

/**
 * Carga Google Maps API de forma dinámica
 * @returns Promise que resuelve cuando la API está lista
 */
export function loadGoogleMapsAPI(): Promise<void> {
  // Si ya está cargado, resolver inmediatamente
  if (isGoogleMapsLoaded()) {
    return Promise.resolve()
  }

  // Si ya hay una carga en progreso, reutilizarla
  if (loadPromise) {
    return loadPromise
  }

  loadPromise = new Promise<void>((resolve, reject) => {
    // Verificar si el script ya existe
    if (document.getElementById(GOOGLE_MAPS_SCRIPT_ID)) {
      // Script existe, esperar a que cargue
      const checkLoaded = setInterval(() => {
        if (isGoogleMapsLoaded()) {
          clearInterval(checkLoaded)
          resolve()
        }
      }, 100)

      // Timeout de 15 segundos
      setTimeout(() => {
        clearInterval(checkLoaded)
        if (!isGoogleMapsLoaded()) {
          reject(new Error('Google Maps API timeout'))
        }
      }, 15000)
      return
    }

    // Obtener API key de variable de entorno
    const apiKey = import.meta.env.VITE_GOOGLE_API_KEY

    if (!apiKey) {
      logger.warn('[Google Maps] VITE_GOOGLE_API_KEY no configurada. El autocompletado de direcciones no estará disponible.')
      reject(new Error('Google Maps API key not configured'))
      return
    }

    // Crear y agregar el script
    const script = document.createElement('script')
    script.id = GOOGLE_MAPS_SCRIPT_ID
    script.src = `https://maps.googleapis.com/maps/api/js?key=${apiKey}&libraries=places&loading=async`
    script.async = true
    script.defer = true

    script.onload = (): void => {
      // Esperar a que la API esté completamente inicializada
      const checkReady = setInterval(() => {
        if (isGoogleMapsLoaded()) {
          clearInterval(checkReady)
          resolve()
        }
      }, 100)

      // Timeout
      setTimeout(() => {
        clearInterval(checkReady)
        if (!isGoogleMapsLoaded()) {
          reject(new Error('Google Maps API initialization timeout'))
        }
      }, 10000)
    }

    script.onerror = (): void => {
      loadPromise = null
      reject(new Error('Failed to load Google Maps API'))
    }

    document.head.appendChild(script)
  })

  return loadPromise
}

/**
 * Opciones para el hook useGoogleMaps
 */
export interface UseGoogleMapsOptions {
  /** Si cargar automáticamente al montar (default: true) */
  autoLoad?: boolean
}

/**
 * Estado del hook useGoogleMaps
 */
export interface UseGoogleMapsState {
  /** Si la API está cargada */
  isLoaded: boolean
  /** Si está cargando */
  isLoading: boolean
  /** Mensaje de error si falló la carga */
  error: string | null
  /** Función para cargar manualmente la API */
  load: () => Promise<void>
}

/**
 * Hook para usar Google Maps en componentes React
 *
 * @param options - Opciones de configuración
 * @returns Estado de carga y función de carga manual
 *
 * @example
 * function MyComponent() {
 *   const { isLoaded, error, load } = useGoogleMaps()
 *
 *   useEffect(() => {
 *     load()
 *   }, [load])
 *
 *   if (error) return <p>Error cargando Maps</p>
 *   if (!isLoaded) return <p>Cargando...</p>
 *   return <AddressAutocomplete />
 * }
 */
export function useGoogleMaps(options: UseGoogleMapsOptions = {}): UseGoogleMapsState {
  const { autoLoad = true } = options

  const [isLoaded, setIsLoaded] = useState<boolean>(
    () => isGoogleMapsLoaded()
  )
  const [error, setError] = useState<string | null>(null)
  const [isLoading, setIsLoading] = useState<boolean>(false)

  const load = useCallback(async (): Promise<void> => {
    if (isLoaded) return

    setIsLoading(true)
    setError(null)

    try {
      await loadGoogleMapsAPI()
      setIsLoaded(true)
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : 'Error desconocido al cargar Google Maps'
      setError(errorMessage)
    } finally {
      setIsLoading(false)
    }
  }, [isLoaded])

  // Auto-cargar si está habilitado
  useEffect(() => {
    if (autoLoad && !isLoaded && !isLoading && !error) {
      load()
    }
  }, [autoLoad, isLoaded, isLoading, error, load])

  return {
    isLoaded,
    isLoading,
    error,
    load
  }
}

export default useGoogleMaps

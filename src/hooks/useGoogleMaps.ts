/**
 * Hook para cargar Google Maps API dinámicamente
 *
 * Ventajas sobre carga estática en index.html:
 * - API key en variable de entorno (no expuesta en HTML)
 * - Carga bajo demanda (mejor performance inicial)
 * - Mejor manejo de errores
 */

const GOOGLE_MAPS_SCRIPT_ID = 'google-maps-script'

let loadPromise = null

/**
 * Carga Google Maps API de forma dinámica
 * @returns {Promise<void>}
 */
export function loadGoogleMapsAPI() {
  // Si ya está cargado, resolver inmediatamente
  if (window.google?.maps?.places?.AutocompleteService) {
    return Promise.resolve()
  }

  // Si ya hay una carga en progreso, reutilizarla
  if (loadPromise) {
    return loadPromise
  }

  loadPromise = new Promise((resolve, reject) => {
    // Verificar si el script ya existe
    if (document.getElementById(GOOGLE_MAPS_SCRIPT_ID)) {
      // Script existe, esperar a que cargue
      const checkLoaded = setInterval(() => {
        if (window.google?.maps?.places?.AutocompleteService) {
          clearInterval(checkLoaded)
          resolve()
        }
      }, 100)

      // Timeout de 15 segundos
      setTimeout(() => {
        clearInterval(checkLoaded)
        if (!window.google?.maps?.places?.AutocompleteService) {
          reject(new Error('Google Maps API timeout'))
        }
      }, 15000)
      return
    }

    // Obtener API key de variable de entorno
    const apiKey = import.meta.env.VITE_GOOGLE_API_KEY

    if (!apiKey) {
      console.warn('[Google Maps] VITE_GOOGLE_API_KEY no configurada. El autocompletado de direcciones no estará disponible.')
      reject(new Error('Google Maps API key not configured'))
      return
    }

    // Crear y agregar el script
    const script = document.createElement('script')
    script.id = GOOGLE_MAPS_SCRIPT_ID
    script.src = `https://maps.googleapis.com/maps/api/js?key=${apiKey}&libraries=places&loading=async`
    script.async = true
    script.defer = true

    script.onload = () => {
      // Esperar a que la API esté completamente inicializada
      const checkReady = setInterval(() => {
        if (window.google?.maps?.places?.AutocompleteService) {
          clearInterval(checkReady)
          resolve()
        }
      }, 100)

      // Timeout
      setTimeout(() => {
        clearInterval(checkReady)
        if (!window.google?.maps?.places?.AutocompleteService) {
          reject(new Error('Google Maps API initialization timeout'))
        }
      }, 10000)
    }

    script.onerror = () => {
      loadPromise = null
      reject(new Error('Failed to load Google Maps API'))
    }

    document.head.appendChild(script)
  })

  return loadPromise
}

/**
 * Hook para usar Google Maps en componentes React
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
import { useState, useCallback, useEffect } from 'react'

export function useGoogleMaps({ autoLoad = true } = {}) {
  const [isLoaded, setIsLoaded] = useState(
    () => !!window.google?.maps?.places?.AutocompleteService
  )
  const [error, setError] = useState(null)
  const [isLoading, setIsLoading] = useState(false)

  const load = useCallback(async () => {
    if (isLoaded) return

    setIsLoading(true)
    setError(null)

    try {
      await loadGoogleMapsAPI()
      setIsLoaded(true)
    } catch (err) {
      setError(err.message)
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

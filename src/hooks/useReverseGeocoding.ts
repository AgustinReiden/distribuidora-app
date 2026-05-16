/* global google */
/**
 * Hook para reverse geocoding (coordenadas → direccion) usando Google Maps Geocoder.
 *
 * Complementa al flujo de AddressAutocomplete: cuando el preventista esta parado
 * en el local del cliente y captura GPS, este hook traduce las coordenadas a una
 * direccion legible para autocompletar el campo de direccion.
 *
 * Reutiliza la misma API key (VITE_GOOGLE_API_KEY) y el SDK ya cargado por
 * useGoogleMaps(). google.maps.Geocoder vive en el core del SDK — no requiere
 * libraries adicionales.
 *
 * Costo: $5 USD / 1000 requests (Google Geocoding API).
 */
import { useCallback, useRef, useState } from 'react'
import { useGoogleMaps } from './useGoogleMaps'
import { logger } from '../utils/logger'

export interface ReverseGeocodeResult {
  direccion: string
}

interface UseReverseGeocodingReturn {
  reverseGeocode: (lat: number, lng: number) => Promise<ReverseGeocodeResult | null>
  loading: boolean
  error: string | null
}

export function useReverseGeocoding(): UseReverseGeocodingReturn {
  const { isLoaded } = useGoogleMaps()
  const geocoderRef = useRef<google.maps.Geocoder | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const reverseGeocode = useCallback(
    async (lat: number, lng: number): Promise<ReverseGeocodeResult | null> => {
      if (!isLoaded || !window.google?.maps?.Geocoder) {
        return null
      }
      if (!geocoderRef.current) {
        geocoderRef.current = new window.google.maps.Geocoder()
      }

      setLoading(true)
      setError(null)
      try {
        const response = await geocoderRef.current.geocode({ location: { lat, lng } })
        const first = response.results?.[0]
        if (first?.formatted_address) {
          return { direccion: first.formatted_address }
        }
        return null
      } catch (err) {
        // Errores no bloquean: el GPS ya capturo coords utiles. Solo log.
        const msg = err instanceof Error ? err.message : 'Error desconocido en reverse geocoding'
        logger.warn('[useReverseGeocoding]', msg)
        setError(msg)
        return null
      } finally {
        setLoading(false)
      }
    },
    [isLoaded],
  )

  return { reverseGeocode, loading, error }
}

export default useReverseGeocoding

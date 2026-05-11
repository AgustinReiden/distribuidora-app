import { useCallback } from 'react'

export type GpsStatus = 'ok' | 'denied' | 'unavailable' | 'timeout' | 'error'

export type GpsResult =
  | {
      status: 'ok'
      lat: number
      lng: number
      accuracy: number
      capturadoAt: string
    }
  | { status: Exclude<GpsStatus, 'ok'> }

export interface UseGeolocationCaptureOptions {
  timeoutMs?: number
  enableHighAccuracy?: boolean
  maximumAgeMs?: number
}

/**
 * Captura la posición GPS actual del navegador en una sola llamada.
 *
 * - Resuelve siempre (nunca rechaza). En cualquier escenario de error
 *   devuelve un objeto `{ status: 'denied' | 'unavailable' | 'timeout' | 'error' }`
 *   para que el caller pueda persistir el motivo sin bloquear el flujo de
 *   negocio (ej: confirmar pedido).
 * - Por defecto: timeout 10s, alta precisión, cache de hasta 30s.
 */
export function useGeolocationCapture(options: UseGeolocationCaptureOptions = {}) {
  const {
    timeoutMs = 10_000,
    enableHighAccuracy = true,
    maximumAgeMs = 30_000,
  } = options

  return useCallback((): Promise<GpsResult> => {
    return new Promise((resolve) => {
      if (typeof navigator === 'undefined' || !navigator.geolocation) {
        resolve({ status: 'unavailable' })
        return
      }

      let settled = false
      const safeResolve = (result: GpsResult) => {
        if (settled) return
        settled = true
        resolve(result)
      }

      try {
        navigator.geolocation.getCurrentPosition(
          (pos) => {
            safeResolve({
              status: 'ok',
              lat: pos.coords.latitude,
              lng: pos.coords.longitude,
              accuracy: pos.coords.accuracy,
              capturadoAt: new Date().toISOString(),
            })
          },
          (err) => {
            if (err.code === err.PERMISSION_DENIED) {
              safeResolve({ status: 'denied' })
            } else if (err.code === err.TIMEOUT) {
              safeResolve({ status: 'timeout' })
            } else if (err.code === err.POSITION_UNAVAILABLE) {
              safeResolve({ status: 'unavailable' })
            } else {
              safeResolve({ status: 'error' })
            }
          },
          {
            enableHighAccuracy,
            timeout: timeoutMs,
            maximumAge: maximumAgeMs,
          },
        )
      } catch {
        safeResolve({ status: 'error' })
      }
    })
  }, [enableHighAccuracy, maximumAgeMs, timeoutMs])
}

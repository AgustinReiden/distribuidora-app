import { useCallback } from 'react'
import { consultarPermisoGeolocalizacion } from './useGeolocationPermission'
import { diagnosticoGps, entornoDelEquipo, type DiagnosticoGps, type EntornoEquipo } from '../utils/ubicacionEquipo'

export type GpsStatus = 'ok' | 'denied' | 'unavailable' | 'timeout' | 'error'

export type GpsResult =
  | {
      status: 'ok'
      lat: number
      lng: number
      accuracy: number
      capturadoAt: string
      /** El equipo, la app y el permiso al momento de la captura (#1602). */
      diagnostico?: DiagnosticoGps
    }
  | { status: Exclude<GpsStatus, 'ok'>; diagnostico?: DiagnosticoGps }

export interface UseGeolocationCaptureOptions {
  timeoutMs?: number
  enableHighAccuracy?: boolean
  maximumAgeMs?: number
}

/**
 * La marca de "en este equipo ya hubo una captura exitosa" (#1602). La usa
 * `GeolocationGate` para sondear la ubicación al abrir sin un toque sólo si el
 * equipo ya dio el permiso: en Chrome Android la Permissions API puede quedar en
 * `prompt` después de concedido, así que no alcanza con preguntarle a ella.
 * `localStorage` puede no estar (modo privado, previsualizaciones): todo va con
 * try/catch y, sin marca, se pide con el botón.
 */
const MARCA_CAPTURA_OK = 'gps.captura_ok'

export function huboCapturaExitosa(): boolean {
  try {
    return localStorage.getItem(MARCA_CAPTURA_OK) === '1'
  } catch {
    return false
  }
}

export function marcarCapturaExitosa(): void {
  try {
    localStorage.setItem(MARCA_CAPTURA_OK, '1')
  } catch {
    // sin almacenamiento: la próxima vez se pide con el botón
  }
}

/** Un PERMISSION_DENIED la borra: sondear sin toque ya no le sirve a este equipo. */
export function olvidarCapturaExitosa(): void {
  try {
    localStorage.removeItem(MARCA_CAPTURA_OK)
  } catch {
    // nada que borrar
  }
}

/** ¿Corre como la app instalada? `display-mode: standalone`, o `navigator.standalone` en iOS. */
export function esAppInstalada(): boolean {
  try {
    if (typeof window !== 'undefined' && window.matchMedia?.('(display-mode: standalone)').matches) return true
  } catch {
    // matchMedia ausente o roto: se sigue con lo de iOS
  }
  return typeof navigator !== 'undefined' && (navigator as Navigator & { standalone?: boolean }).standalone === true
}

export function entornoActual(): EntornoEquipo {
  if (typeof navigator === 'undefined') return entornoDelEquipo('', { instalada: false })
  return entornoDelEquipo(navigator.userAgent, {
    instalada: esAppInstalada(),
    maxTouchPoints: navigator.maxTouchPoints ?? 0,
  })
}

/** El diagnóstico del equipo, con el permiso leído ahora. Nunca rechaza. */
export async function diagnosticoDelEquipo(errorCode: number | null): Promise<DiagnosticoGps | undefined> {
  try {
    const permiso = await consultarPermisoGeolocalizacion()
    return diagnosticoGps(entornoActual(), permiso, errorCode)
  } catch {
    return undefined
  }
}

/**
 * Captura la posición GPS actual del navegador en una sola llamada.
 *
 * - Resuelve siempre (nunca rechaza). En cualquier escenario de error
 *   devuelve un objeto `{ status: 'denied' | 'unavailable' | 'timeout' | 'error' }`
 *   para que el caller pueda persistir el motivo sin bloquear el flujo de
 *   negocio (ej: confirmar pedido).
 * - Por defecto: timeout 10s, alta precisión, cache de hasta 30s.
 * - Con el resultado va el `diagnostico` del equipo (#1602), que se guarda con
 *   el pedido o la visita. El permiso se lee después de la captura: si el
 *   navegador acaba de preguntar, es lo que contestó el preventista.
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
        void diagnosticoDelEquipo(null).then(diagnostico => resolve({ status: 'unavailable', diagnostico }))
        return
      }

      let settled = false
      const safeResolve = (result: GpsResult, errorCode: number | null) => {
        if (settled) return
        settled = true
        void diagnosticoDelEquipo(errorCode).then(diagnostico =>
          resolve(diagnostico ? { ...result, diagnostico } : result),
        )
      }

      try {
        navigator.geolocation.getCurrentPosition(
          (pos) => {
            marcarCapturaExitosa()
            safeResolve({
              status: 'ok',
              lat: pos.coords.latitude,
              lng: pos.coords.longitude,
              accuracy: pos.coords.accuracy,
              capturadoAt: new Date().toISOString(),
            }, null)
          },
          (err) => {
            if (err.code === err.PERMISSION_DENIED) {
              olvidarCapturaExitosa()
              safeResolve({ status: 'denied' }, err.code)
            } else if (err.code === err.TIMEOUT) {
              safeResolve({ status: 'timeout' }, err.code)
            } else if (err.code === err.POSITION_UNAVAILABLE) {
              safeResolve({ status: 'unavailable' }, err.code)
            } else {
              safeResolve({ status: 'error' }, err.code)
            }
          },
          {
            enableHighAccuracy,
            timeout: timeoutMs,
            maximumAge: maximumAgeMs,
          },
        )
      } catch {
        safeResolve({ status: 'error' }, null)
      }
    })
  }, [enableHighAccuracy, maximumAgeMs, timeoutMs])
}

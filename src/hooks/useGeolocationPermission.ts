import { useCallback, useEffect, useState } from 'react'

export type GeoPermissionState = 'granted' | 'prompt' | 'denied' | 'unsupported'

/**
 * Una consulta suelta del permiso, sin suscribirse (#1602). Nunca rechaza: si
 * la API no existe o falla, `'unsupported'`. Ojo que en Chrome Android puede
 * quedar en `'prompt'` después de concedido (ver `GeolocationGate`).
 */
export async function consultarPermisoGeolocalizacion(): Promise<GeoPermissionState> {
  if (typeof navigator === 'undefined' || !navigator.permissions?.query) return 'unsupported'
  try {
    const status = await navigator.permissions.query({ name: 'geolocation' })
    const s = status?.state
    return s === 'granted' || s === 'prompt' || s === 'denied' ? s : 'unsupported'
  } catch {
    return 'unsupported'
  }
}

/**
 * Hook reactivo que expone el estado del permiso de geolocation del browser.
 *
 * - Usa la Permissions API (`navigator.permissions.query({name:'geolocation'})`)
 *   y se suscribe a cambios para reaccionar si el usuario lo modifica desde
 *   settings sin recargar.
 * - En browsers donde `navigator.permissions` no existe (algunos Safari
 *   viejos) devuelve `'unsupported'` y el caller debe degradar al flujo
 *   legacy (intentar `getCurrentPosition` directamente y manejar el error).
 *
 * `refetch()` re-consulta el estado on-demand. Útil después de redirigir al
 * usuario a settings del browser para que reactive el permiso.
 */
export function useGeolocationPermission(): {
  state: GeoPermissionState
  refetch: () => Promise<void>
} {
  const [state, setState] = useState<GeoPermissionState>('prompt')

  const query = useCallback(async (): Promise<GeoPermissionState> => {
    if (typeof navigator === 'undefined' || !navigator.permissions) {
      return 'unsupported'
    }
    try {
      const status = await navigator.permissions.query({ name: 'geolocation' })
      return status.state as GeoPermissionState
    } catch {
      return 'unsupported'
    }
  }, [])

  const refetch = useCallback(async () => {
    setState(await query())
  }, [query])

  useEffect(() => {
    let cancelled = false
    let status: PermissionStatus | null = null
    const onChange = () => {
      if (status && !cancelled) setState(status.state as GeoPermissionState)
    }

    ;(async () => {
      if (typeof navigator === 'undefined' || !navigator.permissions) {
        if (!cancelled) setState('unsupported')
        return
      }
      try {
        status = await navigator.permissions.query({ name: 'geolocation' })
        if (cancelled) return
        setState(status.state as GeoPermissionState)
        status.addEventListener('change', onChange)
      } catch {
        if (!cancelled) setState('unsupported')
      }
    })()

    return () => {
      cancelled = true
      if (status) status.removeEventListener('change', onChange)
    }
  }, [])

  return { state, refetch }
}

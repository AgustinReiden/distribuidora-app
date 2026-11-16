/**
 * GeolocationGate
 *
 * Wrappea UI que requiere GPS obligatorio (visitas, pedidos de preventistas).
 *
 * Diseño: el gate no confía sólo en `navigator.permissions.query({name:'geolocation'})`.
 * La Permissions API es notoriamente poco confiable en Chrome Android: puede
 * devolver `'prompt'` indefinidamente después de que el usuario aprueba el
 * permiso, y a veces nunca dispara el evento `change`. El síntoma en campo era
 * "el preventista activa la ubicación pero la pantalla 'Activá la ubicación'
 * no se va, no lo deja crear el pedido". Por eso lo que decide si el permiso
 * anda es lo que reporta el propio geolocation API:
 *
 * - Click en "Activar GPS" → `getCurrentPosition`.
 * - Success → pasa a `'allowed'` y renderiza children.
 * - Error `PERMISSION_DENIED` → pantalla `'blocked'` con instrucciones según el
 *   equipo y la causa (`instruccionesDesbloqueo`).
 * - Cualquier otro error (timeout / position_unavailable / generic) → también
 *   pasa a `'allowed'`: el permiso fue otorgado y solo falló el sensor. El
 *   flujo de captura GPS al confirmar el pedido se encarga del motivo de
 *   omisión via ModalMotivoSinGps — no queremos trabar al preventista en el
 *   gate por una falla del sensor.
 *
 * Al montar (#1602) NO se llama a `getCurrentPosition` a ciegas: eso hacía que el
 * navegador preguntara sin contexto al abrir "Nuevo pedido", y un prompt
 * descartado o rechazado así ya no vuelve. El sondeo silencioso corre sólo si el
 * equipo ya tiene el permiso: la Permissions API dice `granted`, o en este equipo
 * ya hubo una captura exitosa (la marca local, por el `'prompt'` eterno de Chrome
 * Android). Si la API dice `denied`, va directo a la pantalla de bloqueo, sin
 * sondear. En cualquier otro caso se muestra "Activá la ubicación" y se pide con
 * el botón. Quien ya tenía el permiso pasa igual que antes, sin tocar nada.
 *
 * El gate sólo se aplica cuando `enabled` es true (típicamente `isPreventista`).
 * Para roles que no requieren GPS (admin, encargado), renderiza children direct.
 */
import { useCallback, useEffect, useState, type ReactNode } from 'react'
import { MapPin, AlertTriangle, Loader2 } from 'lucide-react'
import { Button } from './ui/Button'
import { consultarPermisoGeolocalizacion } from '../hooks/useGeolocationPermission'
import {
  entornoActual,
  huboCapturaExitosa,
  marcarCapturaExitosa,
  olvidarCapturaExitosa,
} from '../hooks/useGeolocationCapture'
import { causaDelBloqueo, instruccionesDesbloqueo, type CausaBloqueo } from '../utils/ubicacionEquipo'

export interface GeolocationGateProps {
  enabled: boolean
  children: ReactNode
  onCancel?: () => void
  /**
   * Permite al preventista saltar el gate cuando el navegador devuelve
   * PERMISSION_DENIED y no logra desbloquearlo. Solo aparece en la pantalla
   * 'blocked', no en idle. Al confirmar, la captura vuelve a dar `denied` y se
   * le pide el motivo (`pideMotivoSinGps`, #1602), que queda en
   * `gps_motivo_omision` junto con `gps_status = 'denied'`.
   */
  allowBypass?: boolean
}

type GateState = 'idle' | 'requesting' | 'allowed' | 'blocked'

const TITULO_BLOQUEO: Record<CausaBloqueo, string> = {
  sitio: 'Ubicación bloqueada',
  sistema: 'La ubicación del teléfono no responde',
}

const TEXTO_BLOQUEO: Record<CausaBloqueo, string> = {
  sitio:
    'Este sitio tiene bloqueado el acceso a tu ubicación. Para registrar visitas y pedidos tenés que volver a permitirlo.',
  sistema:
    'El sitio tiene permiso, pero el teléfono no entrega la ubicación: puede estar apagada, o el navegador no tener permiso del teléfono.',
}

export default function GeolocationGate({
  enabled,
  children,
  onCancel,
  allowBypass = true,
}: GeolocationGateProps) {
  const [gateState, setGateState] = useState<GateState>('idle')
  const [causa, setCausa] = useState<CausaBloqueo>('sitio')

  const bloquear = useCallback(async () => {
    olvidarCapturaExitosa()
    // El permiso se lee DESPUÉS del error: si el navegador acaba de preguntar,
    // es lo que contestó. `denied` (o no se sabe) es el sitio; `granted` o
    // `prompt` con PERMISSION_DENIED es el teléfono o el navegador.
    setCausa(causaDelBloqueo(await consultarPermisoGeolocalizacion()))
    setGateState('blocked')
  }, [])

  useEffect(() => {
    if (!enabled) return
    if (typeof navigator === 'undefined' || !navigator.geolocation) {
      // Sin geolocation API: dejar pasar (el flujo legacy de captura maneja la
      // ausencia con status='unavailable').
      setGateState('allowed')
      return
    }
    let cancelled = false
    void (async () => {
      const permiso = await consultarPermisoGeolocalizacion()
      if (cancelled) return
      if (permiso === 'denied') {
        setCausa('sitio')
        setGateState('blocked')
        return
      }
      // Sin el permiso ya dado, un `getCurrentPosition` acá haría preguntar al
      // navegador sin que el preventista haya tocado nada.
      if (permiso !== 'granted' && !huboCapturaExitosa()) return
      // Sondeo silencioso: usa la posición cacheada del browser (no fuerza
      // alta precisión, no dispara nuevo fix).
      navigator.geolocation.getCurrentPosition(
        () => {
          if (cancelled) return
          marcarCapturaExitosa()
          setGateState('allowed')
        },
        (err) => {
          if (cancelled) return
          if (err.code === err.PERMISSION_DENIED) void bloquear()
          // timeout/unavailable/error en probe silencioso: dejar en 'idle' para
          // que el preventista vea el botón "Activar GPS" y dispare un intento
          // explícito con alta precisión.
        },
        { enableHighAccuracy: false, timeout: 5_000, maximumAge: 5 * 60_000 },
      )
    })()
    return () => {
      cancelled = true
    }
  }, [enabled, bloquear])

  const handleRequest = useCallback(() => {
    if (typeof navigator === 'undefined' || !navigator.geolocation) {
      setGateState('allowed')
      return
    }
    setGateState('requesting')
    navigator.geolocation.getCurrentPosition(
      () => {
        marcarCapturaExitosa()
        setGateState('allowed')
      },
      (err) => {
        if (err.code === err.PERMISSION_DENIED) {
          void bloquear()
        } else {
          // El usuario otorgó el permiso pero el sensor falló (timeout en
          // interior, position_unavailable, etc.). Dejar pasar: al confirmar
          // el pedido se vuelve a intentar y, si falla de nuevo, el flujo de
          // ModalMotivoSinGps captura el motivo. No queremos atascar al
          // preventista en el gate por una falla transitoria del GPS.
          setGateState('allowed')
        }
      },
      { enableHighAccuracy: true, timeout: 10_000, maximumAge: 30_000 },
    )
  }, [bloquear])

  if (!enabled) return <>{children}</>
  if (gateState === 'allowed') return <>{children}</>

  if (gateState === 'blocked') {
    return (
      <div className="space-y-4 p-2">
        <div className="flex flex-col items-center text-center gap-3 py-2">
          <div className="w-14 h-14 rounded-full bg-red-100 dark:bg-red-900/30 flex items-center justify-center">
            <AlertTriangle className="w-7 h-7 text-red-600 dark:text-red-400" />
          </div>
          <h3 className="text-lg font-semibold text-gray-900 dark:text-white">
            {TITULO_BLOQUEO[causa]}
          </h3>
          <p className="text-sm text-gray-600 dark:text-gray-400 max-w-md">
            {TEXTO_BLOQUEO[causa]}
          </p>
        </div>
        <div className="bg-gray-50 dark:bg-gray-700/30 border border-gray-200 dark:border-gray-700 rounded-lg p-3">
          <p className="text-xs font-semibold text-gray-700 dark:text-gray-300 mb-2">
            Cómo reactivarlo:
          </p>
          <ol className="text-xs text-gray-700 dark:text-gray-300 space-y-1.5 list-decimal pl-4">
            {instruccionesDesbloqueo(entornoActual(), causa).map((line, i) => (
              <li key={i}>{line}</li>
            ))}
          </ol>
        </div>
        <Button type="button" variant="primary" size="lg" onClick={handleRequest} className="w-full">
          Ya lo activé, reintentar
        </Button>
        {allowBypass && (
          <div className="text-center">
            <button
              type="button"
              onClick={() => setGateState('allowed')}
              className="w-full py-2 text-sm font-medium text-amber-700 hover:text-amber-800 dark:text-amber-400 dark:hover:text-amber-300 underline underline-offset-2"
            >
              Continuar sin GPS
            </button>
            <p className="text-xs text-gray-500 dark:text-gray-400">
              Al confirmar te vamos a pedir el motivo.
            </p>
          </div>
        )}
        {onCancel && (
          <button
            type="button"
            onClick={onCancel}
            className="w-full py-2 text-sm text-gray-500 hover:text-gray-700 dark:text-gray-400"
          >
            Cancelar
          </button>
        )}
      </div>
    )
  }

  // idle / requesting
  return (
    <div className="space-y-4 p-2">
      <div className="flex flex-col items-center text-center gap-3 py-4">
        <div className="w-14 h-14 rounded-full bg-blue-100 dark:bg-blue-900/30 flex items-center justify-center">
          <MapPin className="w-7 h-7 text-blue-600 dark:text-blue-400" />
        </div>
        <h3 className="text-lg font-semibold text-gray-900 dark:text-white">
          Activá la ubicación para continuar
        </h3>
        <p className="text-sm text-gray-600 dark:text-gray-400 max-w-md">
          Para registrar visitas y pedidos como preventista necesitamos tu ubicación
          actual. Cuando aprietes el botón el navegador te va a preguntar — elegí
          <strong> "Permitir"</strong>.
        </p>
      </div>
      <Button
        type="button"
        variant="primary"
        size="lg"
        onClick={handleRequest}
        disabled={gateState === 'requesting'}
        className="w-full"
      >
        {gateState === 'requesting' ? (
          <>
            <Loader2 className="w-4 h-4 animate-spin" /> Esperando respuesta…
          </>
        ) : (
          <>
            <MapPin className="w-4 h-4" /> Activar GPS
          </>
        )}
      </Button>
      {onCancel && (
        <button
          type="button"
          onClick={onCancel}
          className="w-full py-2 text-sm text-gray-500 hover:text-gray-700 dark:text-gray-400"
        >
          Cancelar
        </button>
      )}
    </div>
  )
}

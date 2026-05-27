/**
 * GeolocationGate
 *
 * Wrappea UI que requiere GPS obligatorio (visitas, pedidos de preventistas).
 *
 * Diseño: el gate es totalmente driven por `navigator.geolocation.getCurrentPosition`,
 * sin depender de `navigator.permissions.query({name:'geolocation'})`. La
 * Permissions API es notoriamente poco confiable en Chrome Android: puede
 * devolver `'prompt'` indefinidamente después de que el usuario aprueba el
 * permiso, y a veces nunca dispara el evento `change`. El síntoma en campo era
 * "el preventista activa la ubicación pero la pantalla 'Activá la ubicación'
 * no se va, no lo deja crear el pedido". Acá confiamos solo en lo que el
 * propio geolocation API reporta:
 *
 * - Click en "Activar GPS" → `getCurrentPosition`.
 * - Success → pasa a `'allowed'` y renderiza children.
 * - Error `PERMISSION_DENIED` → pantalla `'blocked'` con instrucciones por SO.
 * - Cualquier otro error (timeout / position_unavailable / generic) → también
 *   pasa a `'allowed'`: el permiso fue otorgado y solo falló el sensor. El
 *   flujo de captura GPS al confirmar el pedido se encarga del motivo de
 *   omisión via ModalMotivoSinGps — no queremos trabar al preventista en el
 *   gate por una falla del sensor.
 *
 * El gate sólo se aplica cuando `enabled` es true (típicamente `isPreventista`).
 * Para roles que no requieren GPS (admin, encargado), renderiza children direct.
 */
import { useCallback, useEffect, useState, type ReactNode } from 'react'
import { MapPin, AlertTriangle, Loader2 } from 'lucide-react'

export interface GeolocationGateProps {
  enabled: boolean
  children: ReactNode
  onCancel?: () => void
  /**
   * Permite al preventista saltar el gate cuando el navegador devuelve
   * PERMISSION_DENIED y no logra desbloquearlo. El pedido se crea igual
   * (queda gps_status='denied' en la fila). Solo aparece en la pantalla
   * 'blocked', no en idle.
   */
  allowBypass?: boolean
}

type Browser = 'chrome-android' | 'ios-safari' | 'chrome-desktop' | 'firefox' | 'other'
type GateState = 'idle' | 'requesting' | 'allowed' | 'blocked'

function detectBrowser(): Browser {
  if (typeof navigator === 'undefined') return 'other'
  const ua = navigator.userAgent
  const isAndroid = /Android/i.test(ua)
  const isIOS = /iPhone|iPad|iPod/i.test(ua)
  const isChrome = /Chrome/i.test(ua) && !/Edg|OPR/i.test(ua)
  const isFirefox = /Firefox/i.test(ua)
  if (isAndroid && isChrome) return 'chrome-android'
  if (isIOS) return 'ios-safari'
  if (isFirefox) return 'firefox'
  if (isChrome) return 'chrome-desktop'
  return 'other'
}

function instructionsFor(browser: Browser): string[] {
  switch (browser) {
    case 'chrome-android':
      return [
        '1. Tocá los tres puntos (⋮) arriba a la derecha.',
        '2. Entrá a "Configuración del sitio" o "Información del sitio".',
        '3. Buscá "Ubicación" y elegí "Permitir".',
        '4. Volvé acá y tocá "Ya lo activé".',
      ]
    case 'ios-safari':
      return [
        '1. Abrí Configuración del iPhone.',
        '2. Privacidad y seguridad → Localización → Safari (o Sitios web).',
        '3. Elegí "Al usar la app".',
        '4. Volvé acá y tocá "Ya lo activé".',
      ]
    case 'chrome-desktop':
      return [
        '1. Hacé click en el candado a la izquierda de la barra de dirección.',
        '2. Buscá "Ubicación" y cambialo a "Permitir".',
        '3. Recargá la página o tocá "Ya lo activé".',
      ]
    case 'firefox':
      return [
        '1. Hacé click en el candado en la barra de dirección.',
        '2. Buscá "Acceder a su ubicación" y remové el bloqueo.',
        '3. Recargá la página o tocá "Ya lo activé".',
      ]
    default:
      return [
        '1. Buscá los permisos del sitio en tu navegador.',
        '2. Habilitá la ubicación para esta página.',
        '3. Tocá "Ya lo activé".',
      ]
  }
}

export default function GeolocationGate({
  enabled,
  children,
  onCancel,
  allowBypass = true,
}: GeolocationGateProps) {
  const [gateState, setGateState] = useState<GateState>('idle')
  const [browser, setBrowser] = useState<Browser>('other')

  useEffect(() => {
    setBrowser(detectBrowser())
  }, [])

  // Probe silencioso al montar: usa la posición cacheada del browser (no fuerza
  // alta precisión, no dispara nuevo fix). Si el preventista ya tiene permiso
  // granted en una sesión anterior, esto retorna posición inmediatamente y
  // deja pasar sin requerir click. Si nunca pidió permiso, el browser puede
  // disparar prompt — el preventista lo aprueba y también pasa.
  // En cualquier escenario "el permiso está disponible" pasamos a allowed sin
  // depender de Permissions API.
  useEffect(() => {
    if (!enabled) return
    if (typeof navigator === 'undefined' || !navigator.geolocation) {
      // Sin geolocation API: dejar pasar (el flujo legacy de captura maneja la
      // ausencia con status='unavailable').
      setGateState('allowed')
      return
    }
    let cancelled = false
    navigator.geolocation.getCurrentPosition(
      () => {
        if (!cancelled) setGateState('allowed')
      },
      (err) => {
        if (cancelled) return
        if (err.code === err.PERMISSION_DENIED) {
          setGateState('blocked')
        }
        // timeout/unavailable/error en probe silencioso: dejar en 'idle' para
        // que el preventista vea el botón "Activar GPS" y dispare un intento
        // explícito con alta precisión.
      },
      { enableHighAccuracy: false, timeout: 5_000, maximumAge: 5 * 60_000 },
    )
    return () => {
      cancelled = true
    }
  }, [enabled])

  const handleRequest = useCallback(() => {
    if (typeof navigator === 'undefined' || !navigator.geolocation) {
      setGateState('allowed')
      return
    }
    setGateState('requesting')
    navigator.geolocation.getCurrentPosition(
      () => {
        setGateState('allowed')
      },
      (err) => {
        if (err.code === err.PERMISSION_DENIED) {
          setGateState('blocked')
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
  }, [])

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
            Ubicación bloqueada
          </h3>
          <p className="text-sm text-gray-600 dark:text-gray-400 max-w-md">
            El navegador tiene bloqueado el acceso a tu ubicación. Para registrar
            visitas y pedidos tenés que reactivarlo manualmente desde la
            configuración del navegador.
          </p>
        </div>
        <div className="bg-gray-50 dark:bg-gray-700/30 border border-gray-200 dark:border-gray-700 rounded-lg p-3">
          <p className="text-xs font-semibold text-gray-700 dark:text-gray-300 mb-2">
            Cómo reactivarlo:
          </p>
          <ol className="text-xs text-gray-700 dark:text-gray-300 space-y-1.5">
            {instructionsFor(browser).map((line, i) => (
              <li key={i}>{line}</li>
            ))}
          </ol>
        </div>
        <button
          type="button"
          onClick={handleRequest}
          className="w-full py-3 bg-blue-600 hover:bg-blue-700 text-white font-semibold rounded-lg"
        >
          Ya lo activé, reintentar
        </button>
        {allowBypass && (
          <button
            type="button"
            onClick={() => setGateState('allowed')}
            className="w-full py-2 text-sm font-medium text-amber-700 hover:text-amber-800 dark:text-amber-400 dark:hover:text-amber-300 underline underline-offset-2"
          >
            Continuar sin GPS
          </button>
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
      <button
        type="button"
        onClick={handleRequest}
        disabled={gateState === 'requesting'}
        className="w-full py-3 bg-blue-600 hover:bg-blue-700 disabled:bg-blue-400 text-white font-semibold rounded-lg flex items-center justify-center gap-2"
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
      </button>
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

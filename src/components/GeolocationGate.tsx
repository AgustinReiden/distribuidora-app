/**
 * GeolocationGate
 *
 * Wrappea UI que requiere GPS obligatorio (visitas, pedidos de preventistas).
 *
 * - `granted` / `unsupported`: render `children` (en `unsupported` el flujo
 *   legacy del hook de captura igual maneja los errores).
 * - `prompt`: render una pantalla con CTA "Activar GPS" que dispara el dialog
 *   nativo del browser. Solo el primer permiso intencional viene por acá; en
 *   subsiguientes ya queda `granted` o `denied`.
 * - `denied`: render una pantalla bloqueante con instrucciones específicas por
 *   browser/SO (Chrome Android, iOS Safari, Chrome desktop, Firefox). Una vez
 *   que el usuario reactiva el permiso desde settings, el botón "Ya lo activé"
 *   re-consulta y desbloquea.
 *
 * El gate sólo se aplica cuando `enabled` es true (típicamente
 * `isPreventista`). Para roles que no requieren GPS (admin, encargado), el
 * componente renderiza `children` directo sin chequear nada.
 */
import { useCallback, useEffect, useState, type ReactNode } from 'react'
import { MapPin, AlertTriangle, Loader2 } from 'lucide-react'
import { useGeolocationPermission } from '../hooks/useGeolocationPermission'

export interface GeolocationGateProps {
  enabled: boolean
  children: ReactNode
  onCancel?: () => void
}

type Browser = 'chrome-android' | 'ios-safari' | 'chrome-desktop' | 'firefox' | 'other'

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
}: GeolocationGateProps) {
  const { state, refetch } = useGeolocationPermission()
  const [requesting, setRequesting] = useState(false)
  const [browser, setBrowser] = useState<Browser>('other')

  useEffect(() => {
    setBrowser(detectBrowser())
  }, [])

  const handleRequest = useCallback(() => {
    if (typeof navigator === 'undefined' || !navigator.geolocation) return
    setRequesting(true)
    navigator.geolocation.getCurrentPosition(
      () => {
        setRequesting(false)
        void refetch()
      },
      () => {
        setRequesting(false)
        void refetch()
      },
      { enableHighAccuracy: true, timeout: 10_000, maximumAge: 30_000 },
    )
  }, [refetch])

  if (!enabled) return <>{children}</>
  if (state === 'granted' || state === 'unsupported') return <>{children}</>

  if (state === 'prompt') {
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
          disabled={requesting}
          className="w-full py-3 bg-blue-600 hover:bg-blue-700 disabled:bg-blue-400 text-white font-semibold rounded-lg flex items-center justify-center gap-2"
        >
          {requesting ? (
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

  // denied
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
        onClick={() => void refetch()}
        className="w-full py-3 bg-blue-600 hover:bg-blue-700 text-white font-semibold rounded-lg"
      >
        Ya lo activé, reintentar
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

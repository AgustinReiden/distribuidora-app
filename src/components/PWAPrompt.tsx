/**
 * PWA Prompt - Componente para manejar instalación y actualizaciones de PWA
 *
 * Features:
 * - Prompt de instalación nativo
 * - Notificación de actualizaciones disponibles
 * - Registro del Service Worker
 */
import { useState, useEffect, MouseEvent, ReactElement } from 'react'
import { Download, RefreshCw, X, Smartphone } from 'lucide-react'
// @ts-expect-error - virtual:pwa-register/react is provided by vite-plugin-pwa
import { useRegisterSW } from 'virtual:pwa-register/react'
import { logger } from '../utils/logger'

// =============================================================================
// TYPES
// =============================================================================

/** BeforeInstallPromptEvent - Browser event for PWA install prompt */
export interface BeforeInstallPromptEvent extends Event {
  readonly platforms: string[];
  readonly userChoice: Promise<{
    outcome: 'accepted' | 'dismissed';
    platform: string;
  }>;
  prompt(): Promise<void>;
}

/** Extend Navigator for standalone mode on iOS */
declare global {
  interface Navigator {
    standalone?: boolean;
  }
  interface Window {
    MSStream?: unknown;
  }
}

/** Props for PWAPrompt component (no props currently) */
export interface PWAPromptProps {
  // No props currently
}

export function PWAPrompt(_props: PWAPromptProps): ReactElement | null {
  const [showInstallPrompt, setShowInstallPrompt] = useState<boolean>(false)
  const [deferredPrompt, setDeferredPrompt] = useState<BeforeInstallPromptEvent | null>(null)
  const [isIOS, setIsIOS] = useState<boolean>(false)
  const [isStandalone, setIsStandalone] = useState<boolean>(false)

  // Registro del Service Worker con auto-update
  const {
    needRefresh: [needRefresh, setNeedRefresh],
    offlineReady: [offlineReady, setOfflineReady],
    updateServiceWorker
  } = useRegisterSW({
    onRegistered(r: ServiceWorkerRegistration | undefined) {
      // Verificar actualizaciones cada hora
      if (r) {
        setInterval(() => {
          r.update()
        }, 60 * 60 * 1000)
      }
    },
    onRegisterError(error: Error) {
      logger.error('SW registration error:', error)
    }
  })

  useEffect(() => {
    // Detectar iOS
    const isIOSDevice = /iPad|iPhone|iPod/.test(navigator.userAgent) && !window.MSStream
    setIsIOS(isIOSDevice)

    // Detectar si ya está instalado como PWA
    const isInStandaloneMode = window.matchMedia('(display-mode: standalone)').matches ||
      window.navigator.standalone === true
    setIsStandalone(isInStandaloneMode)

    // Capturar evento de instalación
    const handleBeforeInstallPrompt = (e: Event): void => {
      e.preventDefault()
      setDeferredPrompt(e as BeforeInstallPromptEvent)

      // Mostrar prompt después de 30 segundos de uso
      setTimeout(() => {
        if (!isInStandaloneMode) {
          setShowInstallPrompt(true)
        }
      }, 30000)
    }

    window.addEventListener('beforeinstallprompt', handleBeforeInstallPrompt)

    return () => {
      window.removeEventListener('beforeinstallprompt', handleBeforeInstallPrompt)
    }
  }, [])

  const handleInstall = async (): Promise<void> => {
    if (!deferredPrompt) return

    deferredPrompt.prompt()
    const { outcome } = await deferredPrompt.userChoice

    if (outcome === 'accepted') {
      setShowInstallPrompt(false)
    }
    setDeferredPrompt(null)
  }

  const handleDismissInstall = (): void => {
    setShowInstallPrompt(false)
    // No mostrar de nuevo por 7 días
    localStorage.setItem('pwa-install-dismissed', Date.now().toString())
  }

  const handleUpdate = (): void => {
    updateServiceWorker(true)
  }

  const handleDismissOffline = (): void => {
    setOfflineReady(false)
  }

  const handleDismissRefresh = (): void => {
    setNeedRefresh(false)
  }

  // Verificar si el usuario ya descartó el prompt recientemente
  useEffect(() => {
    const dismissedTime = localStorage.getItem('pwa-install-dismissed')
    if (dismissedTime) {
      const daysSinceDismissed = (Date.now() - parseInt(dismissedTime)) / (1000 * 60 * 60 * 24)
      if (daysSinceDismissed < 7) {
        setShowInstallPrompt(false)
      }
    }
  }, [])

  // No mostrar nada si ya está instalado
  if (isStandalone) return null

  return (
    <>
      {/* Notificación de listo para offline */}
      {offlineReady && (
        <div className="fixed bottom-4 left-4 right-4 md:left-auto md:right-4 md:w-96 bg-green-600 text-white p-4 rounded-lg shadow-lg z-50 animate-slide-up">
          <div className="flex items-start gap-3">
            <Download className="w-5 h-5 mt-0.5 flex-shrink-0" />
            <div className="flex-1">
              <p className="font-medium">Listo para usar offline</p>
              <p className="text-sm text-green-100 mt-1">
                La aplicación está disponible sin conexión a internet.
              </p>
            </div>
            <button
              onClick={handleDismissOffline}
              className="p-1 hover:bg-green-500 rounded"
              aria-label="Cerrar notificación"
            >
              <X className="w-4 h-4" />
            </button>
          </div>
        </div>
      )}

      {/* Notificación de actualización disponible */}
      {needRefresh && (
        <div className="fixed bottom-4 left-4 right-4 md:left-auto md:right-4 md:w-96 bg-blue-600 text-white p-4 rounded-lg shadow-lg z-50 animate-slide-up">
          <div className="flex items-start gap-3">
            <RefreshCw className="w-5 h-5 mt-0.5 flex-shrink-0" />
            <div className="flex-1">
              <p className="font-medium">Nueva versión disponible</p>
              <p className="text-sm text-blue-100 mt-1">
                Hay una actualización lista para instalar.
              </p>
              <div className="flex gap-2 mt-3">
                <button
                  onClick={handleUpdate}
                  className="px-3 py-1.5 bg-white text-blue-600 rounded font-medium text-sm hover:bg-blue-50 transition-colors"
                >
                  Actualizar ahora
                </button>
                <button
                  onClick={handleDismissRefresh}
                  className="px-3 py-1.5 text-blue-100 hover:text-white text-sm"
                >
                  Más tarde
                </button>
              </div>
            </div>
            <button
              onClick={handleDismissRefresh}
              className="p-1 hover:bg-blue-500 rounded"
              aria-label="Cerrar notificación"
            >
              <X className="w-4 h-4" />
            </button>
          </div>
        </div>
      )}

      {/* Prompt de instalación */}
      {showInstallPrompt && !needRefresh && !offlineReady && (
        <div className="fixed bottom-4 left-4 right-4 md:left-auto md:right-4 md:w-96 bg-white dark:bg-gray-800 p-4 rounded-lg shadow-lg border border-gray-200 dark:border-gray-700 z-50 animate-slide-up">
          <div className="flex items-start gap-3">
            <div className="p-2 bg-blue-100 dark:bg-blue-900 rounded-lg">
              <Smartphone className="w-6 h-6 text-blue-600 dark:text-blue-400" />
            </div>
            <div className="flex-1">
              <p className="font-medium text-gray-900 dark:text-white">
                Instalar Distribuidora
              </p>
              <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">
                {isIOS
                  ? 'Toca el botón compartir y "Agregar a inicio"'
                  : 'Instala la app para acceso rápido y uso offline'}
              </p>
              {!isIOS && deferredPrompt && (
                <div className="flex gap-2 mt-3">
                  <button
                    onClick={handleInstall}
                    className="px-3 py-1.5 bg-blue-600 text-white rounded font-medium text-sm hover:bg-blue-700 transition-colors"
                  >
                    Instalar
                  </button>
                  <button
                    onClick={handleDismissInstall}
                    className="px-3 py-1.5 text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200 text-sm"
                  >
                    Ahora no
                  </button>
                </div>
              )}
            </div>
            <button
              onClick={handleDismissInstall}
              className="p-1 hover:bg-gray-100 dark:hover:bg-gray-700 rounded text-gray-400"
              aria-label="Cerrar"
            >
              <X className="w-4 h-4" />
            </button>
          </div>
        </div>
      )}
    </>
  )
}

export default PWAPrompt

import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { QueryClientProvider } from '@tanstack/react-query'
import { ReactQueryDevtools } from '@tanstack/react-query-devtools'
import './index.css'
import './styles/high-contrast.css'
import App from './App'
import { initSentry } from './lib/sentry'
import { initWebVitals } from './lib/webVitals'
import { initAccessibilityAudit } from './lib/accessibility'
import { registrarServiceWorker } from './utils/serviceWorker'
import { logger } from './utils/logger'
import { queryClient } from './lib/queryClient'

/**
 * Corre un paso de arranque sin dejar que su error mate el boot.
 *
 * El arranque tiene una sola obligacion: llegar al createRoot. Todo lo de
 * antes (service worker, telemetria) es accesorio, y hasta ahora cualquier
 * excepcion ahi rechazaba la promesa y la app nunca se montaba: el #root
 * quedaba vacio y en la PWA de iOS eso es una pantalla blanca de la que no se
 * sale ni cerrando la app, porque en modo standalone no hay barra de
 * direcciones ni boton de recargar.
 */
function pasoOpcional(nombre: string, paso: () => void): void {
  try {
    paso()
  } catch (err) {
    logger.error(`[bootstrap] Fallo el paso opcional "${nombre}"`, err)
  }
}

function bootstrapApp(): void {
  // Sentry primero, asi los errores del propio arranque tambien se reportan.
  pasoOpcional('sentry', initSentry)

  // El service worker: es lo que hace que la app abra aunque el telefono no
  // llegue a bajar el index.html. Ver src/utils/serviceWorker.ts.
  pasoOpcional('service-worker', registrarServiceWorker)

  // Monitoreo de performance
  pasoOpcional('web-vitals', initWebVitals)

  // Auditoría de accesibilidad (solo en desarrollo)
  if (import.meta.env.DEV) {
    pasoOpcional('a11y', initAccessibilityAudit)
  }

  const contenedor = document.getElementById('root')
  if (!contenedor) {
    // Sin contenedor no hay nada que hacer, pero al menos queda registrado en
    // vez de romper con un TypeError mudo.
    logger.error('[bootstrap] No existe #root en el documento')
    return
  }

  createRoot(contenedor).render(
    <StrictMode>
      <QueryClientProvider client={queryClient}>
        <App />
        {import.meta.env.DEV && <ReactQueryDevtools initialIsOpen={false} />}
      </QueryClientProvider>
    </StrictMode>,
  )
}

try {
  bootstrapApp()
} catch (err) {
  // Ultima red. El cartel de rescate del index.html sigue en pie (createRoot
  // nunca llego a limpiarlo), asi que la usuaria ve el boton "Reintentar".
  logger.error('[bootstrap] La app no pudo arrancar', err)
}

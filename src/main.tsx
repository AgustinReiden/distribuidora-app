import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import './styles/high-contrast.css'
import App from './App'
import { initSentry } from './lib/sentry'
import { initWebVitals } from './lib/webVitals'
import { initAccessibilityAudit } from './lib/accessibility'

// Inicializar Sentry antes de renderizar la app
initSentry()

// Inicializar Web Vitals para monitoreo de performance
initWebVitals()

// Inicializar auditoría de accesibilidad (solo en desarrollo)
if (import.meta.env.DEV) {
  initAccessibilityAudit()
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)

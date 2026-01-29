import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { ReactQueryDevtools } from '@tanstack/react-query-devtools'
import './index.css'
import './styles/high-contrast.css'
import App from './App'
import { initSentry } from './lib/sentry'
import { initWebVitals } from './lib/webVitals'
import { initAccessibilityAudit } from './lib/accessibility'

// Configurar TanStack Query
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 5 * 60 * 1000, // 5 minutos antes de considerar datos "stale"
      gcTime: 30 * 60 * 1000,   // 30 minutos en cache antes de garbage collection
      retry: 2,                  // Reintentar 2 veces en caso de error
      refetchOnWindowFocus: false, // No refetch al volver a la ventana
    },
  },
})

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
    <QueryClientProvider client={queryClient}>
      <App />
      {import.meta.env.DEV && <ReactQueryDevtools initialIsOpen={false} />}
    </QueryClientProvider>
  </StrictMode>,
)

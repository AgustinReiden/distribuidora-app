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

// Configurar TanStack Query con retry inteligente y backoff exponencial
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 5 * 60 * 1000, // 5 minutos antes de considerar datos "stale"
      gcTime: 30 * 60 * 1000,   // 30 minutos en cache antes de garbage collection
      refetchOnWindowFocus: false, // No refetch al volver a la ventana
      // Retry inteligente: no reintentar errores 4xx (cliente), solo 5xx (servidor)
      retry: (failureCount, error) => {
        // No reintentar errores de cliente (4xx)
        const status = (error as { status?: number })?.status
        if (status && status >= 400 && status < 500) {
          return false
        }
        // Máximo 3 reintentos para errores de servidor
        return failureCount < 3
      },
      // Backoff exponencial: 1s, 2s, 4s (máximo 30s)
      retryDelay: (attemptIndex) => Math.min(1000 * Math.pow(2, attemptIndex), 30000),
    },
    mutations: {
      // Mutations también con retry inteligente
      retry: (failureCount, error) => {
        const status = (error as { status?: number })?.status
        if (status && status >= 400 && status < 500) {
          return false
        }
        return failureCount < 2
      },
      retryDelay: (attemptIndex) => Math.min(1000 * Math.pow(2, attemptIndex), 10000),
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

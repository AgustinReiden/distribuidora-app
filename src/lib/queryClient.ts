/**
 * Instancia única de TanStack Query.
 *
 * Vive en su propio módulo (no inline en `main.tsx`) para que `useAuth`
 * pueda importarla y llamar `queryClient.clear()` en logout sin depender de
 * `main.tsx` -- que renderiza `<App>`, que termina montando `useAuth` -- y
 * armar un ciclo de imports.
 */
import { QueryClient, QueryCache } from '@tanstack/react-query'
import { notifyQueryError } from './queryErrorNotifier'

export const queryClient = new QueryClient({
  // Una query que falla tras agotar los reintentos (ver `retry` abajo) hoy
  // se mostraba en silencio: la vista caía al empty state ("No hay pedidos")
  // como si la sucursal estuviera vacía. Este onError es la única alerta
  // *global* — cada container además decide su propio estado de error inline
  // (ver `QueryErrorState`); las dos cosas conviven a propósito.
  queryCache: new QueryCache({
    onError: (_error, query) => {
      if (query.meta?.silentError) return
      notifyQueryError('No se pudo cargar la información. Verificá tu conexión.')
    },
  }),
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

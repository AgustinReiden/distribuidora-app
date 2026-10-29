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
import { esErrorReintentable } from '../utils/errorDeSupabase'

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
      // El error plano de supabase-js no trae `status` (#1265, igual que las
      // mutations en #576): mirando sólo eso, un 42501 o un PGRST201 se
      // reintentaba 3 veces y la pantalla quedaba ~7 s cargando para mostrar el
      // mismo error. Se discrimina por `code` (ver `esErrorReintentable`); el
      // `status` queda para los errores que sí lo traen (auth).
      retry: (failureCount, error) => {
        const status = (error as { status?: number })?.status
        if (status && status >= 400 && status < 500) {
          return false
        }
        return failureCount < 3 && esErrorReintentable(error)
      },
      // Backoff exponencial: 1s, 2s, 4s (máximo 30s)
      retryDelay: (attemptIndex) => Math.min(1000 * Math.pow(2, attemptIndex), 30000),
    },
    mutations: {
      // Sin retry por default (#576): `error.status` no existe en un
      // PostgrestError (viene con message/details/hint/code), así que esta
      // guarda de 4xx nunca se activaba y toda mutation fallida se
      // reintentaba — incluida una no idempotente cuyo error fue un timeout
      // después de que el INSERT ya había entrado. Reintentar es seguro sólo
      // para las RPCs con idempotencia propia (las 4 de pago, mig 167, y
      // crear_pedido_idempotente): esas declaran su propio `retry` en su
      // `useMutation`.
      retry: false,
    },
  },
})

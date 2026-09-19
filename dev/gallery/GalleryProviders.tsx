/**
 * Los providers REALES de la app, alimentados con valores de fixture.
 *
 * No hay copias de `ThemeProvider` ni de `NotificationProvider`: son los de
 * `src/contexts`, para que el toggle de tema de la galería haga exactamente lo
 * mismo que el de la app (la clase `dark` / `high-contrast` en `<html>`).
 *
 * Lo único que se reemplaza es la FUENTE DE DATOS:
 *  - `AuthDataProvider` ya recibe su valor por prop, así que se le pasa uno literal.
 *  - `SucursalProvider` NO: consulta `usuario_sucursales` contra Supabase al
 *    montarse. Por eso se usa el contexto crudo (`SucursalContext.Provider`), que
 *    el módulo exporta por default.
 *  - El `QueryClient` es propio, con la cache precargada (ver fixtures/cacheSeed).
 *
 * Este archivo exporta SÓLO componentes (`react-refresh/only-export-components`).
 */
import { useMemo, useState, type ReactNode } from 'react'
import { QueryClient, QueryCache, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { ThemeProvider } from '../../src/contexts/ThemeContext'
import { NotificationProvider } from '../../src/contexts/NotificationContext'
import { AuthDataProvider } from '../../src/contexts/AuthDataContext'
import SucursalContext from '../../src/contexts/SucursalContext'
import type { RolUsuario } from '../../src/types'
import { authDataDeRol, sucursalContextDeRol } from './fixtures/auth'
import { sembrarCacheGaleria } from './fixtures/cacheSeed'

function crearQueryClient(): QueryClient {
  const qc = new QueryClient({
    // Silencio deliberado: el `queryClient` de producción avisa por toast cuando
    // una query falla. Acá una query sin precargar apunta al Supabase
    // placeholder y va a fallar siempre; un toast rojo permanente taparía la
    // galería sin decir nada útil.
    queryCache: new QueryCache({ onError: () => {} }),
    defaultOptions: {
      queries: {
        // Sin reintentos y sin refetch: la cache precargada es la única fuente.
        // `staleTime: Infinity` hace que una query ya sembrada nunca corra su
        // `queryFn`, así que el componente ve los datos de fixture y no toca la red.
        retry: false,
        refetchOnWindowFocus: false,
        refetchOnMount: false,
        refetchOnReconnect: false,
        refetchInterval: false,
        staleTime: Infinity,
        gcTime: Infinity,
      },
      mutations: { retry: false },
    },
  })
  sembrarCacheGaleria(qc)
  return qc
}

export default function GalleryProviders({
  rol,
  children,
}: {
  rol: RolUsuario
  children: ReactNode
}) {
  // Una sola instancia por montaje: recrearla en cada render borraría la cache
  // precargada y los paneles quedarían vacíos.
  const [queryClient] = useState(crearQueryClient)

  const authData = useMemo(() => authDataDeRol(rol), [rol])
  const sucursal = useMemo(() => sucursalContextDeRol(rol), [rol])

  return (
    <QueryClientProvider client={queryClient}>
      <ThemeProvider>
        <NotificationProvider>
          <MemoryRouter initialEntries={['/pedidos']}>
            <SucursalContext.Provider value={sucursal}>
              <AuthDataProvider value={authData}>{children}</AuthDataProvider>
            </SucursalContext.Provider>
          </MemoryRouter>
        </NotificationProvider>
      </ThemeProvider>
    </QueryClientProvider>
  )
}

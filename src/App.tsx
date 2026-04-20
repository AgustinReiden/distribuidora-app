import { useEffect, lazy, Suspense, ReactElement, useCallback, useMemo } from 'react'
import { BrowserRouter, useLocation, Navigate, Route, Routes } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import {
  AuthProvider,
  setErrorNotifier,
  useAuth,
  useMermas,
  usePedidos,
  useProductos
} from './hooks/supabase'
import { useInvalidateMetricas } from './hooks/queries'
import { ThemeProvider } from './contexts/ThemeContext'
import { NotificationProvider, useNotification } from './contexts/NotificationContext'
import { AuthDataProvider, type AuthDataContextValue } from './contexts/AuthDataContext'
import { SucursalProvider, useSucursal } from './contexts/SucursalContext'
import type { PerfilDB } from './types'
import { useOfflineSync, type UseOfflineSyncReturn } from './hooks/useOfflineSync'
import { useRealtimeInvalidation } from './hooks/useRealtimeInvalidation'
import { useSyncManager, type SyncDependencies } from './hooks/useSyncManager'
import { trackFirstAuthenticatedRender } from './utils/authPerformance'
import LoginScreen from './components/auth/LoginScreen'
import SinSucursalScreen from './components/SinSucursalScreen'
import ErrorBoundary from './components/ErrorBoundary'
import TopNavigation from './components/layout/TopNavigation'
import OfflineIndicator from './components/layout/OfflineIndicator'
import SyncStatusBanner from './components/SyncStatusBanner'
import SkipLinks from './components/a11y/SkipLinks'
import {
  AnalyticsContainer,
  ClientesContainer,
  ComisionesContainer,
  ComprasContainer,
  TransferenciasContainer,
  DashboardContainer,
  GruposPrecioContainer,
  PromocionesContainer,
  PedidosContainer,
  ProductosContainer,
  ProveedoresContainer,
  RecorridoPreventistaContainer,
  RecorridosContainer,
  ReportesContainer,
  UsuariosContainer
} from './components/containers'

const VistaRendiciones = lazy(() => import('./components/vistas/VistaRendiciones'))
const VistaSalvedades = lazy(() => import('./components/vistas/VistaSalvedades'))

function LoadingVista(): ReactElement {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

type PendingSyncRuntimeProps = Pick<
  UseOfflineSyncReturn,
  'isOnline' | 'pedidosPendientes' | 'mermasPendientes' | 'sincronizando' | 'sincronizarPedidos' | 'sincronizarMermas'
>

function PendingSyncRuntime({
  isOnline,
  pedidosPendientes,
  mermasPendientes,
  sincronizando,
  sincronizarPedidos,
  sincronizarMermas
}: PendingSyncRuntimeProps): ReactElement {
  const notify = useNotification()
  const { productos, descontarStock, refetch: refetchProductos } = useProductos()
  const { crearPedido, refetch: refetchPedidos } = usePedidos()
  const { registrarMerma, refetch: refetchMermas } = useMermas()
  const invalidateMetricas = useInvalidateMetricas()

  const refetchMetricas = useCallback(async () => {
    invalidateMetricas()
  }, [invalidateMetricas])

  const { handleSincronizar } = useSyncManager({
    isOnline,
    pedidosPendientes,
    mermasPendientes,
    sincronizando,
    productos,
    sincronizarPedidos,
    sincronizarMermas,
    crearPedido: crearPedido as SyncDependencies['crearPedido'],
    descontarStock: descontarStock as SyncDependencies['descontarStock'],
    registrarMerma: registrarMerma as SyncDependencies['registrarMerma'],
    refetchPedidos,
    refetchProductos,
    refetchMermas,
    refetchMetricas,
    notify: notify as SyncDependencies['notify']
  })

  return (
    <OfflineIndicator
      isOnline={isOnline}
      pedidosPendientes={pedidosPendientes.map(pedido => ({
        offlineId: pedido.offlineId,
        clienteId: String(pedido.clienteId),
        items: pedido.items.map(item => ({
          producto_id: item.productoId,
          cantidad: item.cantidad
        })),
        total: pedido.total,
        creadoOffline: pedido.creadoOffline
      }))}
      mermasPendientes={mermasPendientes.map(merma => ({
        offlineId: merma.offlineId,
        productoNombre: productos.find(producto => producto.id === merma.productoId)?.nombre,
        cantidad: merma.cantidad,
        motivo: merma.motivo
      }))}
      sincronizando={sincronizando}
      onSincronizar={handleSincronizar}
    />
  )
}

function MainApp(): ReactElement {
  const { user, perfil, logout, authReady } = useAuth()
  const globalRol = perfil?.rol ?? null

  return (
    <SucursalProvider userId={user?.id ?? null} globalRol={globalRol}>
      <MainAppInner
        user={user}
        perfil={perfil}
        logout={logout}
        authReady={authReady}
      />
    </SucursalProvider>
  )
}

function MainAppInner({ user, perfil, logout, authReady }: {
  user: { id: string; email?: string } | null
  perfil: PerfilDB | null
  logout: () => Promise<void>
  authReady: boolean
}): ReactElement {
  const notify = useNotification()
  const location = useLocation()
  const offlineSync = useOfflineSync()
  const {
    currentSucursalId,
    currentSucursalNombre,
    currentSucursalRol,
    sucursales,
    loading: sucursalLoading,
  } = useSucursal()
  const {
    isOnline,
    pedidosPendientes,
    mermasPendientes,
    sincronizando,
    refreshPendingOperations,
    sincronizarPedidos,
    sincronizarMermas
  } = offlineSync

  const hasPendingSync = pedidosPendientes.length > 0 || mermasPendientes.length > 0

  useEffect(() => {
    setErrorNotifier((message: string) => notify.error(message))
  }, [notify])

  useEffect(() => {
    if (user && perfil) {
      trackFirstAuthenticatedRender(location.pathname || '/')
    }
  }, [location.pathname, perfil, user])

  useRealtimeInvalidation({ enabled: isOnline })

  const handleLogout = useCallback(async (): Promise<void> => {
    try {
      await logout()
    } catch (err) {
      console.error('Error during logout:', err)
    }
  }, [logout])

  // Use sucursal-resolved role for permissions
  const effectiveRol = currentSucursalRol ?? perfil?.rol
  const isAdmin = effectiveRol === 'admin'
  const isPreventista = effectiveRol === 'preventista'
  const isTransportista = effectiveRol === 'transportista'
  const isEncargado = effectiveRol === 'encargado'
  const isAdminOrEncargado = isAdmin || isEncargado

  const defaultRoute = (isAdmin || isPreventista || isEncargado) ? '/dashboard' : '/pedidos'

  const authDataValue = useMemo<AuthDataContextValue>(() => ({
    user,
    perfil,
    authReady,
    isAdmin,
    isPreventista,
    isTransportista,
    isEncargado,
    isAdminOrEncargado,
    isOnline,
    logout: handleLogout,
    currentSucursalId,
    currentSucursalNombre,
  }), [user, perfil, authReady, isAdmin, isPreventista, isTransportista, isEncargado, isAdminOrEncargado, isOnline, handleLogout, currentSucursalId, currentSucursalNombre])

  const handleRetrySync = useCallback(async () => {
    await refreshPendingOperations()
  }, [refreshPendingOperations])

  // Block the app if the authenticated user has no sucursales assigned.
  // Replaces the previous phantom fallback that silently pretended the
  // user was on sucursal id=1 (C6). Placed after all hooks so rules-of-hooks
  // are respected.
  if (!sucursalLoading && sucursales.length === 0) {
    return <SinSucursalScreen onLogout={handleLogout} />
  }

  return (
    <AuthDataProvider value={authDataValue}>
      <div className="min-h-screen bg-gray-100 dark:bg-gray-900 transition-colors">
        <SkipLinks />
        <TopNavigation perfil={perfil} onLogout={handleLogout} />

        <main id="main-content" className="pt-20 pb-6 px-4" role="main">
          <div className="max-w-7xl mx-auto">
            <Suspense fallback={<LoadingVista />}>
              <Routes>
                <Route path="/" element={<Navigate to={defaultRoute} replace />} />

                <Route
                  path="/dashboard"
                  element={(isAdminOrEncargado || isPreventista) ? <DashboardContainer /> : <Navigate to="/pedidos" replace />}
                />

                <Route path="/pedidos" element={<PedidosContainer />} />
                <Route path="/clientes" element={<ClientesContainer />} />
                <Route path="/productos" element={<ProductosContainer />} />

                <Route
                  path="/reportes"
                  element={isAdminOrEncargado ? <ReportesContainer /> : <Navigate to="/pedidos" replace />}
                />

                <Route
                  path="/usuarios"
                  element={isAdmin ? <UsuariosContainer /> : <Navigate to="/pedidos" replace />}
                />

                <Route
                  path="/recorridos"
                  element={isAdminOrEncargado ? <RecorridosContainer /> : <Navigate to="/pedidos" replace />}
                />

                <Route
                  path="/recorrido-preventista"
                  element={isAdminOrEncargado ? <RecorridoPreventistaContainer /> : <Navigate to="/pedidos" replace />}
                />

                <Route
                  path="/compras"
                  element={isAdminOrEncargado ? <ComprasContainer /> : <Navigate to="/pedidos" replace />}
                />

                <Route
                  path="/proveedores"
                  element={isAdminOrEncargado ? <ProveedoresContainer /> : <Navigate to="/pedidos" replace />}
                />

                <Route
                  path="/condiciones-mayoristas"
                  element={isAdminOrEncargado ? <GruposPrecioContainer /> : <Navigate to="/pedidos" replace />}
                />

                <Route
                  path="/promociones"
                  element={isAdminOrEncargado ? <PromocionesContainer /> : <Navigate to="/pedidos" replace />}
                />

                <Route
                  path="/transferencias"
                  element={isAdminOrEncargado ? <TransferenciasContainer /> : <Navigate to="/pedidos" replace />}
                />

                <Route
                  path="/rendiciones"
                  element={isAdminOrEncargado ? <VistaRendiciones /> : <Navigate to="/pedidos" replace />}
                />

                <Route
                  path="/salvedades"
                  element={isAdminOrEncargado ? <VistaSalvedades /> : <Navigate to="/pedidos" replace />}
                />

                <Route
                  path="/analytics"
                  element={isAdminOrEncargado ? <AnalyticsContainer /> : <Navigate to="/pedidos" replace />}
                />

                <Route
                  path="/comisiones"
                  element={isAdminOrEncargado ? <ComisionesContainer /> : <Navigate to="/pedidos" replace />}
                />

                <Route path="*" element={<Navigate to={defaultRoute} replace />} />
              </Routes>
            </Suspense>
          </div>
        </main>

        {hasPendingSync ? (
          <PendingSyncRuntime
            isOnline={isOnline}
            pedidosPendientes={pedidosPendientes}
            mermasPendientes={mermasPendientes}
            sincronizando={sincronizando}
            sincronizarPedidos={sincronizarPedidos}
            sincronizarMermas={sincronizarMermas}
          />
        ) : (
          !isOnline && <OfflineIndicator isOnline={isOnline} />
        )}

        <SyncStatusBanner onRetrySync={handleRetrySync} />
      </div>
    </AuthDataProvider>
  )
}

function AppContent(): ReactElement {
  const { user, perfil, loading } = useAuth()

  if (loading) {
    return (
      <div className="min-h-screen bg-gray-100 dark:bg-gray-900 flex items-center justify-center transition-colors">
        <Loader2 className="w-8 h-8 animate-spin text-blue-600" aria-label="Cargando" />
      </div>
    )
  }

  return (user && perfil) ? <MainApp /> : <LoginScreen />
}

export default function App(): ReactElement {
  return (
    <ErrorBoundary>
      <BrowserRouter>
        <ThemeProvider>
          <AuthProvider>
            <NotificationProvider>
              <AppContent />
            </NotificationProvider>
          </AuthProvider>
        </ThemeProvider>
      </BrowserRouter>
    </ErrorBoundary>
  )
}

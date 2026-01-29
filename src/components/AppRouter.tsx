/**
 * AppRouter
 *
 * Componente de enrutamiento principal usando React Router v6.
 * Reemplaza el sistema manual de vistas basado en estado.
 *
 * Las vistas reciben datos del AppDataContext y handlers del padre.
 */
import React, { Suspense, lazy, ReactElement } from 'react'
import { Routes, Route, Navigate, useLocation } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import { useAppData } from '../contexts/AppDataContext'

// =============================================================================
// LAZY LOADED VIEWS
// =============================================================================

const VistaDashboard = lazy(() => import('./vistas/VistaDashboard'))
const VistaPedidos = lazy(() => import('./vistas/VistaPedidos'))
const VistaClientes = lazy(() => import('./vistas/VistaClientes'))
const VistaProductos = lazy(() => import('./vistas/VistaProductos'))
const VistaReportes = lazy(() => import('./vistas/VistaReportes'))
const VistaUsuarios = lazy(() => import('./vistas/VistaUsuarios'))
const VistaRecorridos = lazy(() => import('./vistas/VistaRecorridos'))
const VistaCompras = lazy(() => import('./vistas/VistaCompras'))
const VistaProveedores = lazy(() => import('./vistas/VistaProveedores'))
const VistaRendiciones = lazy(() => import('./vistas/VistaRendiciones'))
const VistaSalvedades = lazy(() => import('./vistas/VistaSalvedades'))

// =============================================================================
// LOADING FALLBACK
// =============================================================================

function LoadingVista(): ReactElement {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" aria-label="Cargando vista" />
    </div>
  )
}

// =============================================================================
// PROTECTED ROUTE WRAPPER
// =============================================================================

interface ProtectedRouteProps {
  children: ReactElement
  requireAdmin?: boolean
  requireAdminOrPreventista?: boolean
}

function ProtectedRoute({
  children,
  requireAdmin = false,
  requireAdminOrPreventista = false
}: ProtectedRouteProps): ReactElement {
  const { isAdmin, isPreventista } = useAppData()

  if (requireAdmin && !isAdmin) {
    return <Navigate to="/pedidos" replace />
  }

  if (requireAdminOrPreventista && !isAdmin && !isPreventista) {
    return <Navigate to="/pedidos" replace />
  }

  return children
}

// =============================================================================
// PROPS INTERFACES FOR ROUTER
// =============================================================================

export interface AppRouterProps {
  // Vista handlers and props passed from MainApp
  vistaProps: {
    dashboard: React.ComponentProps<typeof VistaDashboard>
    pedidos: React.ComponentProps<typeof VistaPedidos>
    clientes: React.ComponentProps<typeof VistaClientes>
    productos: React.ComponentProps<typeof VistaProductos>
    reportes: React.ComponentProps<typeof VistaReportes>
    usuarios: React.ComponentProps<typeof VistaUsuarios>
    recorridos: React.ComponentProps<typeof VistaRecorridos>
    compras: React.ComponentProps<typeof VistaCompras>
    proveedores: React.ComponentProps<typeof VistaProveedores>
  }
}

// =============================================================================
// HOOK PARA OBTENER VISTA ACTUAL
// =============================================================================

// eslint-disable-next-line react-refresh/only-export-components
export function useCurrentVista(): string {
  const location = useLocation()
  return location.pathname.replace('/', '') || 'dashboard'
}

// =============================================================================
// MAIN ROUTER
// =============================================================================

export default function AppRouter({ vistaProps }: AppRouterProps): ReactElement {
  const { isAdmin, isPreventista } = useAppData()

  // Determinar la ruta por defecto según el rol
  const defaultRoute = (isAdmin || isPreventista) ? '/dashboard' : '/pedidos'

  return (
    <Suspense fallback={<LoadingVista />}>
      <Routes>
        {/* Ruta raíz - redirige según rol */}
        <Route path="/" element={<Navigate to={defaultRoute} replace />} />

        {/* Dashboard - admin y preventista */}
        <Route
          path="/dashboard"
          element={
            <ProtectedRoute requireAdminOrPreventista>
              <VistaDashboard {...vistaProps.dashboard} />
            </ProtectedRoute>
          }
        />

        {/* Pedidos - todos los roles */}
        <Route path="/pedidos" element={<VistaPedidos {...vistaProps.pedidos} />} />

        {/* Clientes - todos los roles */}
        <Route path="/clientes" element={<VistaClientes {...vistaProps.clientes} />} />

        {/* Productos - todos los roles */}
        <Route path="/productos" element={<VistaProductos {...vistaProps.productos} />} />

        {/* Reportes - solo admin */}
        <Route
          path="/reportes"
          element={
            <ProtectedRoute requireAdmin>
              <VistaReportes {...vistaProps.reportes} />
            </ProtectedRoute>
          }
        />

        {/* Usuarios - solo admin */}
        <Route
          path="/usuarios"
          element={
            <ProtectedRoute requireAdmin>
              <VistaUsuarios {...vistaProps.usuarios} />
            </ProtectedRoute>
          }
        />

        {/* Recorridos - solo admin */}
        <Route
          path="/recorridos"
          element={
            <ProtectedRoute requireAdmin>
              <VistaRecorridos {...vistaProps.recorridos} />
            </ProtectedRoute>
          }
        />

        {/* Compras - solo admin */}
        <Route
          path="/compras"
          element={
            <ProtectedRoute requireAdmin>
              <VistaCompras {...vistaProps.compras} />
            </ProtectedRoute>
          }
        />

        {/* Proveedores - solo admin */}
        <Route
          path="/proveedores"
          element={
            <ProtectedRoute requireAdmin>
              <VistaProveedores {...vistaProps.proveedores} />
            </ProtectedRoute>
          }
        />

        {/* Rendiciones - solo admin */}
        <Route
          path="/rendiciones"
          element={
            <ProtectedRoute requireAdmin>
              <VistaRendiciones />
            </ProtectedRoute>
          }
        />

        {/* Salvedades - solo admin */}
        <Route
          path="/salvedades"
          element={
            <ProtectedRoute requireAdmin>
              <VistaSalvedades />
            </ProtectedRoute>
          }
        />

        {/* Fallback - ruta no encontrada */}
        <Route path="*" element={<Navigate to={defaultRoute} replace />} />
      </Routes>
    </Suspense>
  )
}

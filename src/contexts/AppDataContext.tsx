/**
 * AppDataContext
 *
 * Contexto centralizado para todos los datos de la aplicacion.
 * Evita prop drilling y permite acceso directo desde cualquier componente.
 */
import React, { createContext, useContext, ReactNode, useMemo } from 'react'
import type {
  ClienteDB,
  ProductoDB,
  PedidoDB,
  PerfilDB,
  ProveedorDB,
  CompraDB,
  MermaDB,
  RecorridoDB,
  DashboardMetricas,
  ReportePreventista,
  FiltrosPedidosState
} from '../types'

// =============================================================================
// TYPES
// =============================================================================

export interface AppDataContextValue {
  // Entidades principales
  clientes: ClienteDB[]
  productos: ProductoDB[]
  pedidos: PedidoDB[]
  pedidosFiltrados: PedidoDB[]
  usuarios: PerfilDB[]
  transportistas: PerfilDB[]
  proveedores: ProveedorDB[]
  compras: CompraDB[]
  mermas: MermaDB[]
  recorridos: RecorridoDB[]

  // Dashboard
  metricas: DashboardMetricas | null
  reportePreventistas: ReportePreventista[]
  reporteInicializado: boolean

  // Filtros
  filtros: FiltrosPedidosState
  filtroPeriodo: string

  // Categorias derivadas
  categorias: string[]

  // Estados de carga
  loading: {
    clientes: boolean
    productos: boolean
    pedidos: boolean
    usuarios: boolean
    compras: boolean
    recorridos: boolean
    metricas: boolean
    reporte: boolean
    optimizacion: boolean
  }

  // Usuario actual
  user: { id: string; email?: string } | null
  perfil: PerfilDB | null
  isAdmin: boolean
  isPreventista: boolean
  isTransportista: boolean

  // Estado de conexion
  isOnline: boolean

  // Ruta optimizada
  rutaOptimizada: unknown | null
  errorOptimizacion: string | null
}

// =============================================================================
// CONTEXT
// =============================================================================

const AppDataContext = createContext<AppDataContextValue | null>(null)

// =============================================================================
// PROVIDER
// =============================================================================

interface AppDataProviderProps {
  children: ReactNode
  value: AppDataContextValue
}

export function AppDataProvider({ children, value }: AppDataProviderProps): React.ReactElement {
  // Memoizar el valor para evitar re-renders innecesarios
  const memoizedValue = useMemo(() => value, [value])

  return (
    <AppDataContext.Provider value={memoizedValue}>
      {children}
    </AppDataContext.Provider>
  )
}

// =============================================================================
// HOOKS
// =============================================================================

/**
 * Hook para acceder a todos los datos de la aplicacion
 */
// eslint-disable-next-line react-refresh/only-export-components
export function useAppData(): AppDataContextValue {
  const context = useContext(AppDataContext)
  if (!context) {
    throw new Error('useAppData debe usarse dentro de un AppDataProvider')
  }
  return context
}

/**
 * Hook para acceder solo a los clientes
 */
// eslint-disable-next-line react-refresh/only-export-components
export function useClientesData(): { clientes: ClienteDB[]; loading: boolean } {
  const { clientes, loading } = useAppData()
  return { clientes, loading: loading.clientes }
}

/**
 * Hook para acceder solo a los productos
 */
// eslint-disable-next-line react-refresh/only-export-components
export function useProductosData(): { productos: ProductoDB[]; categorias: string[]; loading: boolean } {
  const { productos, categorias, loading } = useAppData()
  return { productos, categorias, loading: loading.productos }
}

/**
 * Hook para acceder solo a los pedidos
 */
// eslint-disable-next-line react-refresh/only-export-components
export function usePedidosData(): { pedidos: PedidoDB[]; pedidosFiltrados: PedidoDB[]; filtros: FiltrosPedidosState; loading: boolean } {
  const { pedidos, pedidosFiltrados, filtros, loading } = useAppData()
  return { pedidos, pedidosFiltrados, filtros, loading: loading.pedidos }
}

/**
 * Hook para acceder a permisos del usuario
 */
// eslint-disable-next-line react-refresh/only-export-components
export function useUserPermissions(): { user: AppDataContextValue['user']; perfil: PerfilDB | null; isAdmin: boolean; isPreventista: boolean; isTransportista: boolean } {
  const { user, perfil, isAdmin, isPreventista, isTransportista } = useAppData()
  return { user, perfil, isAdmin, isPreventista, isTransportista }
}

export default AppDataContext

/**
 * Barrel export para todos los contextos
 */

// Auth
export { AuthDataProvider, useAuthData, useUserPermissions } from './AuthDataContext'
export type { AuthDataContextValue } from './AuthDataContext'

// Clientes
export { ClientesProvider, useClientes } from './ClientesContext'
export type { ClientesContextValue } from './ClientesContext'

// Productos
export { ProductosProvider, useProductos } from './ProductosContext'
export type { ProductosContextValue } from './ProductosContext'

// Pedidos
export { PedidosProvider, usePedidosContext } from './PedidosContext'
export type { PedidosContextValue } from './PedidosContext'

// Operations (compras, proveedores, mermas, recorridos, usuarios)
export { OperationsProvider, useOperations, useUsuariosContext } from './OperationsContext'
export type { OperationsContextValue } from './OperationsContext'

// Legacy - AppDataContext (mantener para compatibilidad)
export { AppDataProvider, useAppData, useClientesData, useProductosData, usePedidosData } from './AppDataContext'
export type { AppDataContextValue } from './AppDataContext'

// Theme
export { ThemeProvider, useTheme } from './ThemeContext'

// Notifications
export { NotificationProvider, useNotification } from './NotificationContext'

// Handlers (para reducir props drilling)
export { HandlersProvider } from './HandlersContext'
export type {
  PedidoActionsContext,
  ClienteActionsContext,
  ProductoActionsContext,
  CompraActionsContext,
  ProveedorActionsContext,
  UsuarioActionsContext
} from './HandlersContext'

// Hooks de handlers (separados para cumplir con react-refresh)
export {
  usePedidoActions,
  useClienteActions,
  useProductoActions,
  useCompraActions,
  useProveedorActions,
  useUsuarioActions
} from '../hooks/useHandlerActions'

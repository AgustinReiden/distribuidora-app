/**
 * Barrel export para todos los contextos
 */

// Auth
export { AuthDataProvider, useAuthData, useUserPermissions } from './AuthDataContext'
export type { AuthDataContextValue } from './AuthDataContext'

// Sucursal (multi-tenant)
export { SucursalProvider, useSucursal } from './SucursalContext'
export type { SucursalContextValue, SucursalInfo } from './SucursalContext'

// Theme
export { ThemeProvider, useTheme } from './ThemeContext'

// Notifications
export { NotificationProvider, useNotification } from './NotificationContext'

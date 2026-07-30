/**
 * AuthDataContext
 *
 * Contexto ligero solo para datos de autenticación y permisos.
 * Reemplaza AppDataContext para evitar cargar todos los datos globalmente.
 */
import React, { createContext, useContext, ReactNode } from 'react'
import type { PerfilDB, RolUsuario } from '../types'

// =============================================================================
// TYPES
// =============================================================================

export interface AuthDataContextValue {
  user: { id: string; email?: string } | null
  perfil: PerfilDB | null
  authReady: boolean
  isAdmin: boolean
  isPreventista: boolean
  isPreventistaTaco: boolean
  isAnyPreventista: boolean
  isTransportista: boolean
  isEncargado: boolean
  isAdminOrEncargado: boolean
  /**
   * Rol primario en la sucursal activa + capacidades extra (mig 155).
   * Para gating de NAVEGACIÓN (qué pantallas ve). Los permisos sensibles se
   * siguen evaluando contra `perfil.rol` vía src/lib/permisos.ts.
   */
  rolesEfectivos: RolUsuario[]
  isOnline: boolean
  logout: () => Promise<void>
  currentSucursalId: number | null
  currentSucursalNombre: string | null
}

// =============================================================================
// CONTEXT
// =============================================================================

const AuthDataContext = createContext<AuthDataContextValue | null>(null)

// =============================================================================
// PROVIDER
// =============================================================================

interface AuthDataProviderProps {
  children: ReactNode
  value: AuthDataContextValue
}

export function AuthDataProvider({ children, value }: AuthDataProviderProps): React.ReactElement {
  return (
    <AuthDataContext.Provider value={value}>
      {children}
    </AuthDataContext.Provider>
  )
}

// =============================================================================
// HOOKS
// =============================================================================

/**
 * Hook para acceder a datos de autenticación
 */
// eslint-disable-next-line react-refresh/only-export-components
export function useAuthData(): AuthDataContextValue {
  const context = useContext(AuthDataContext)
  if (!context) {
    throw new Error('useAuthData debe usarse dentro de un AuthDataProvider')
  }
  return context
}

/**
 * Hook para permisos del usuario
 */
// eslint-disable-next-line react-refresh/only-export-components
export function useUserPermissions() {
  const { user, perfil, isAdmin, isPreventista, isPreventistaTaco, isAnyPreventista, isTransportista, isEncargado, isAdminOrEncargado, rolesEfectivos } = useAuthData()
  return { user, perfil, isAdmin, isPreventista, isPreventistaTaco, isAnyPreventista, isTransportista, isEncargado, isAdminOrEncargado, rolesEfectivos }
}

export default AuthDataContext

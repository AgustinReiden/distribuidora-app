/**
 * AuthDataContext
 *
 * Contexto ligero solo para datos de autenticación y permisos.
 * Reemplaza AppDataContext para evitar cargar todos los datos globalmente.
 */
import React, { createContext, useContext, ReactNode } from 'react'
import type { PerfilDB } from '../types'

// =============================================================================
// TYPES
// =============================================================================

export interface AuthDataContextValue {
  user: { id: string; email?: string } | null
  perfil: PerfilDB | null
  isAdmin: boolean
  isPreventista: boolean
  isTransportista: boolean
  isOnline: boolean
  logout: () => Promise<void>
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
  const { user, perfil, isAdmin, isPreventista, isTransportista } = useAuthData()
  return { user, perfil, isAdmin, isPreventista, isTransportista }
}

export default AuthDataContext

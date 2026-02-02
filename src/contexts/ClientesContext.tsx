/**
 * ClientesContext
 *
 * Contexto específico para datos de clientes.
 * Separado de AppDataContext para evitar re-renders innecesarios.
 */
import React, { createContext, useContext, ReactNode, useMemo } from 'react'
import type { ClienteDB } from '../types'

// =============================================================================
// TYPES
// =============================================================================

export interface ClientesContextValue {
  clientes: ClienteDB[]
  loading: boolean
}

// =============================================================================
// CONTEXT
// =============================================================================

const ClientesContext = createContext<ClientesContextValue | null>(null)

// =============================================================================
// PROVIDER
// =============================================================================

interface ClientesProviderProps {
  children: ReactNode
  value: ClientesContextValue
}

export function ClientesProvider({ children, value }: ClientesProviderProps): React.ReactElement {
  const memoizedValue = useMemo(() => value, [value])

  return (
    <ClientesContext.Provider value={memoizedValue}>
      {children}
    </ClientesContext.Provider>
  )
}

// =============================================================================
// HOOKS
// =============================================================================

/**
 * Hook para acceder a datos de clientes
 */
// eslint-disable-next-line react-refresh/only-export-components
export function useClientes(): ClientesContextValue {
  const context = useContext(ClientesContext)
  if (!context) {
    throw new Error('useClientes debe usarse dentro de un ClientesProvider')
  }
  return context
}

export default ClientesContext

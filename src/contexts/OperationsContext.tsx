/**
 * OperationsContext
 *
 * Contexto para datos operativos: compras, proveedores, mermas, recorridos.
 * Datos que cambian menos frecuentemente y son usados por admin.
 */
import React, { createContext, useContext, ReactNode, useMemo } from 'react'
import type { CompraDB, ProveedorDB, MermaDB, RecorridoDB, PerfilDB } from '../types'

// =============================================================================
// TYPES
// =============================================================================

export interface OperationsContextValue {
  compras: CompraDB[]
  proveedores: ProveedorDB[]
  mermas: MermaDB[]
  recorridos: RecorridoDB[]
  usuarios: PerfilDB[]
  transportistas: PerfilDB[]
  loading: {
    compras: boolean
    recorridos: boolean
    usuarios: boolean
  }
}

// =============================================================================
// CONTEXT
// =============================================================================

const OperationsContext = createContext<OperationsContextValue | null>(null)

// =============================================================================
// PROVIDER
// =============================================================================

interface OperationsProviderProps {
  children: ReactNode
  value: OperationsContextValue
}

export function OperationsProvider({ children, value }: OperationsProviderProps): React.ReactElement {
  const memoizedValue = useMemo(() => value, [value])

  return (
    <OperationsContext.Provider value={memoizedValue}>
      {children}
    </OperationsContext.Provider>
  )
}

// =============================================================================
// HOOKS
// =============================================================================

/**
 * Hook para acceder a datos operativos
 */
// eslint-disable-next-line react-refresh/only-export-components
export function useOperations(): OperationsContextValue {
  const context = useContext(OperationsContext)
  if (!context) {
    throw new Error('useOperations debe usarse dentro de un OperationsProvider')
  }
  return context
}

/**
 * Hook para acceder solo a usuarios y transportistas
 */
// eslint-disable-next-line react-refresh/only-export-components
export function useUsuariosContext(): { usuarios: PerfilDB[]; transportistas: PerfilDB[]; loading: boolean } {
  const { usuarios, transportistas, loading } = useOperations()
  return { usuarios, transportistas, loading: loading.usuarios }
}

export default OperationsContext

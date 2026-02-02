/**
 * PedidosContext
 *
 * Contexto específico para datos de pedidos y filtros.
 * Separado de AppDataContext para evitar re-renders innecesarios.
 */
import React, { createContext, useContext, ReactNode, useMemo } from 'react'
import type { PedidoDB, FiltrosPedidosState } from '../types'

// =============================================================================
// TYPES
// =============================================================================

export interface PedidosContextValue {
  pedidos: PedidoDB[]
  pedidosFiltrados: PedidoDB[]
  filtros: FiltrosPedidosState
  loading: boolean
}

// =============================================================================
// CONTEXT
// =============================================================================

const PedidosContext = createContext<PedidosContextValue | null>(null)

// =============================================================================
// PROVIDER
// =============================================================================

interface PedidosProviderProps {
  children: ReactNode
  value: PedidosContextValue
}

export function PedidosProvider({ children, value }: PedidosProviderProps): React.ReactElement {
  const memoizedValue = useMemo(() => value, [value])

  return (
    <PedidosContext.Provider value={memoizedValue}>
      {children}
    </PedidosContext.Provider>
  )
}

// =============================================================================
// HOOKS
// =============================================================================

/**
 * Hook para acceder a datos de pedidos
 */
// eslint-disable-next-line react-refresh/only-export-components
export function usePedidosContext(): PedidosContextValue {
  const context = useContext(PedidosContext)
  if (!context) {
    throw new Error('usePedidosContext debe usarse dentro de un PedidosProvider')
  }
  return context
}

export default PedidosContext

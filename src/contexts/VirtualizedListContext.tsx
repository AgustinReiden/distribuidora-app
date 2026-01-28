/**
 * Context para listas virtualizadas
 *
 * Reemplaza el anti-patrón de usar window global para pasar datos
 * a componentes de fila en react-window v2.
 *
 * Beneficios:
 * - Encapsulamiento correcto en React
 * - Compatible con SSR
 * - Fácil de testear
 * - Visible en React DevTools
 */
import React, { createContext, useContext, useMemo, ReactNode } from 'react'
import type { PedidoDB } from '../types'

// =============================================================================
// TYPES
// =============================================================================

export interface VirtualizedListHandlers {
  onVerHistorial?: (pedido: PedidoDB) => void
  onEditarPedido?: (pedido: PedidoDB) => void
  onMarcarEnPreparacion?: (pedido: PedidoDB) => void
  onVolverAPendiente?: (pedido: PedidoDB) => void
  onAsignarTransportista?: (pedido: PedidoDB) => void
  onMarcarEntregado?: (pedido: PedidoDB) => void
  onMarcarEntregadoConSalvedad?: (pedido: PedidoDB) => void
  onDesmarcarEntregado?: (pedido: PedidoDB) => void
  onEliminarPedido?: (pedidoId: string) => void
}

export interface VirtualizedListPermissions {
  isAdmin?: boolean
  isPreventista?: boolean
  isTransportista?: boolean
}

export interface VirtualizedListData {
  pedidos: PedidoDB[]
  handlers: VirtualizedListHandlers
  permissions: VirtualizedListPermissions
}

export interface VirtualizedListProviderProps {
  children: ReactNode
  pedidos: PedidoDB[]
  handlers: VirtualizedListHandlers
  permissions: VirtualizedListPermissions
}

// =============================================================================
// CONTEXT
// =============================================================================

const VirtualizedListContext = createContext<VirtualizedListData | null>(null)

// =============================================================================
// PROVIDER
// =============================================================================

/**
 * Provider para datos de lista virtualizada
 *
 * Usar memoización para evitar re-renders innecesarios de las filas
 */
export function VirtualizedListProvider({
  children,
  pedidos,
  handlers,
  permissions
}: VirtualizedListProviderProps): React.ReactElement {
  // Memoizar el valor para evitar re-renders innecesarios
  const value = useMemo<VirtualizedListData>(() => ({
    pedidos,
    handlers,
    permissions
  }), [pedidos, handlers, permissions])

  return (
    <VirtualizedListContext.Provider value={value}>
      {children}
    </VirtualizedListContext.Provider>
  )
}

// =============================================================================
// HOOK
// =============================================================================

/**
 * Hook para acceder a los datos de la lista virtualizada
 *
 * @throws Error si se usa fuera del VirtualizedListProvider
 */
// eslint-disable-next-line react-refresh/only-export-components
export function useVirtualizedList(): VirtualizedListData {
  const context = useContext(VirtualizedListContext)

  if (!context) {
    throw new Error('useVirtualizedList debe usarse dentro de un VirtualizedListProvider')
  }

  return context
}

/**
 * Hook seguro que no lanza error si no hay provider
 * Útil para componentes que pueden renderizarse fuera del contexto
 */
// eslint-disable-next-line react-refresh/only-export-components
export function useVirtualizedListSafe(): VirtualizedListData | null {
  return useContext(VirtualizedListContext)
}

// =============================================================================
// EXPORTS
// =============================================================================

export { VirtualizedListContext }
export default VirtualizedListProvider

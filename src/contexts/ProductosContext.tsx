/**
 * ProductosContext
 *
 * Contexto específico para datos de productos y categorías.
 * Separado de AppDataContext para evitar re-renders innecesarios.
 */
import React, { createContext, useContext, ReactNode, useMemo } from 'react'
import type { ProductoDB } from '../types'

// =============================================================================
// TYPES
// =============================================================================

export interface ProductosContextValue {
  productos: ProductoDB[]
  categorias: string[]
  loading: boolean
}

// =============================================================================
// CONTEXT
// =============================================================================

const ProductosContext = createContext<ProductosContextValue | null>(null)

// =============================================================================
// PROVIDER
// =============================================================================

interface ProductosProviderProps {
  children: ReactNode
  value: ProductosContextValue
}

export function ProductosProvider({ children, value }: ProductosProviderProps): React.ReactElement {
  const memoizedValue = useMemo(() => value, [value])

  return (
    <ProductosContext.Provider value={memoizedValue}>
      {children}
    </ProductosContext.Provider>
  )
}

// =============================================================================
// HOOKS
// =============================================================================

/**
 * Hook para acceder a datos de productos
 */
// eslint-disable-next-line react-refresh/only-export-components
export function useProductos(): ProductosContextValue {
  const context = useContext(ProductosContext)
  if (!context) {
    throw new Error('useProductos debe usarse dentro de un ProductosProvider')
  }
  return context
}

export default ProductosContext

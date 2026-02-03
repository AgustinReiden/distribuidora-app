/**
 * Hooks para acceder a los handlers de la aplicación
 *
 * Estos hooks permiten acceder a las acciones desde cualquier componente
 * sin necesidad de props drilling.
 *
 * NOTA: Separados de HandlersContext.tsx para cumplir con react-refresh/only-export-components
 */
import { useContext } from 'react';
import {
  PedidoActionsCtx,
  ClienteActionsCtx,
  ProductoActionsCtx,
  CompraActionsCtx,
  ProveedorActionsCtx,
  UsuarioActionsCtx,
  type PedidoActionsContext,
  type ClienteActionsContext,
  type ProductoActionsContext,
  type CompraActionsContext,
  type ProveedorActionsContext,
  type UsuarioActionsContext
} from '../contexts/HandlersContext';

/**
 * Hook para acceder a las acciones de pedidos
 * @throws Error si se usa fuera de HandlersProvider
 */
export function usePedidoActions(): PedidoActionsContext {
  const context = useContext(PedidoActionsCtx);
  if (!context) {
    throw new Error('usePedidoActions debe usarse dentro de HandlersProvider');
  }
  return context;
}

/**
 * Hook para acceder a las acciones de clientes
 * @throws Error si se usa fuera de HandlersProvider
 */
export function useClienteActions(): ClienteActionsContext {
  const context = useContext(ClienteActionsCtx);
  if (!context) {
    throw new Error('useClienteActions debe usarse dentro de HandlersProvider');
  }
  return context;
}

/**
 * Hook para acceder a las acciones de productos
 * @throws Error si se usa fuera de HandlersProvider
 */
export function useProductoActions(): ProductoActionsContext {
  const context = useContext(ProductoActionsCtx);
  if (!context) {
    throw new Error('useProductoActions debe usarse dentro de HandlersProvider');
  }
  return context;
}

/**
 * Hook para acceder a las acciones de compras
 * @throws Error si se usa fuera de HandlersProvider
 */
export function useCompraActions(): CompraActionsContext {
  const context = useContext(CompraActionsCtx);
  if (!context) {
    throw new Error('useCompraActions debe usarse dentro de HandlersProvider');
  }
  return context;
}

/**
 * Hook para acceder a las acciones de proveedores
 * @throws Error si se usa fuera de HandlersProvider
 */
export function useProveedorActions(): ProveedorActionsContext {
  const context = useContext(ProveedorActionsCtx);
  if (!context) {
    throw new Error('useProveedorActions debe usarse dentro de HandlersProvider');
  }
  return context;
}

/**
 * Hook para acceder a las acciones de usuarios
 * @throws Error si se usa fuera de HandlersProvider
 */
export function useUsuarioActions(): UsuarioActionsContext {
  const context = useContext(UsuarioActionsCtx);
  if (!context) {
    throw new Error('useUsuarioActions debe usarse dentro de HandlersProvider');
  }
  return context;
}

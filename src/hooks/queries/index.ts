/**
 * TanStack Query hooks - Barrel export
 *
 * Estos hooks reemplazan los hooks legacy de useState/useEffect
 * con mejor gestión de cache, optimistic updates y background refetching.
 */

// Productos
export {
  productosKeys,
  useProductosQuery,
  useProductoQuery,
  useProductosStockBajoQuery,
  useCrearProductoMutation,
  useActualizarProductoMutation,
  useEliminarProductoMutation,
  useDescontarStockMutation,
  useRestaurarStockMutation,
} from './useProductosQuery'

// Clientes
export {
  clientesKeys,
  useClientesQuery,
  useClienteQuery,
  useClientesByZonaQuery,
  useZonasQuery,
  useCrearClienteMutation,
  useActualizarClienteMutation,
  useEliminarClienteMutation,
} from './useClientesQuery'

// Pedidos
export {
  pedidosKeys,
  usePedidosQuery,
  usePedidoQuery,
  usePedidosByTransportistaQuery,
  usePedidosByClienteQuery,
  useCrearPedidoMutation,
  useCambiarEstadoMutation,
  useActualizarPagoMutation,
  useAsignarTransportistaMutation,
  useEliminarPedidoMutation,
} from './usePedidosQuery'

// Usuarios
export {
  usuariosKeys,
  useUsuariosQuery,
  useUsuarioQuery,
  useUsuariosByRolQuery,
  useTransportistasQuery,
  usePreventistasQuery,
  useActualizarUsuarioMutation,
  useToggleUsuarioActivoMutation,
} from './useUsuariosQuery'

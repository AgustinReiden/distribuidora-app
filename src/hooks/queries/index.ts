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
  usePedidosPaginatedQuery,
  usePedidoQuery,
  usePedidosByTransportistaQuery,
  usePedidosByClienteQuery,
  useCrearPedidoMutation,
  useCambiarEstadoMutation,
  useActualizarPagoMutation,
  useAsignarTransportistaMutation,
  useEliminarPedidoMutation,
  usePedidosNoEntregadosQuery,
  useEntregasMasivasMutation,
  useCancelarPedidoMutation,
  usePedidosNoPagadosQuery,
  usePagosMasivosMutation,
} from './usePedidosQuery'
export type { PaginatedResult } from './usePedidosQuery'

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

// Compras
export {
  comprasKeys,
  useComprasQuery,
  useCompraQuery,
  useComprasByProveedorQuery,
  useRegistrarCompraMutation,
  useAnularCompraMutation,
} from './useComprasQuery'

// Proveedores
export {
  proveedoresKeys,
  useProveedoresQuery,
  useProveedoresActivosQuery,
  useProveedorQuery,
  useCrearProveedorMutation,
  useActualizarProveedorMutation,
  useToggleProveedorActivoMutation,
  useEliminarProveedorMutation,
} from './useProveedoresQuery'

// Mermas
export {
  mermasKeys,
  useMermasQuery,
  useMermasByProductoQuery,
  useMermasByMotivoQuery,
  useRegistrarMermaMutation,
  useMermasResumen,
} from './useMermasQuery'

// Grupos de Precio Mayorista
export {
  gruposPrecioKeys,
  useGruposPrecioQuery,
  usePricingMapQuery,
  useCrearGrupoPrecioMutation,
  useActualizarGrupoPrecioMutation,
  useEliminarGrupoPrecioMutation,
  useToggleGrupoPrecioActivoMutation,
} from './useGruposPrecioQuery'

// Zonas estandarizadas
export {
  zonasKeys,
  useZonasEstandarizadasQuery,
  usePreventistaZonasQuery,
  useCrearZonaMutation,
  useAsignarZonasPrevMutation,
} from './useZonasQuery'
export type { ZonaDB } from './useZonasQuery'

// Transferencias y Sucursales
export {
  transferenciasKeys,
  sucursalesKeys,
  useTransferenciasQuery,
  useSucursalesQuery,
  useCrearSucursalMutation,
  useRegistrarTransferenciaMutation,
} from './useTransferenciasQuery'

// Métricas
export {
  metricasKeys,
  useMetricasQuery,
  useReportePreventistasQuery,
  useInvalidateMetricas,
} from './useMetricasQuery'

// Notas de Crédito
export {
  notasCreditoKeys,
  useNotasCreditoByCompraQuery,
  useRegistrarNotaCreditoMutation,
} from './useNotasCreditoQuery'

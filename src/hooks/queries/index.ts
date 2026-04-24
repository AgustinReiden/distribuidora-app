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

// Categorías
export {
  categoriasKeys,
  useCategoriasQuery,
  useCrearCategoriaMutation,
  useRenombrarCategoriaMutation,
  useEliminarCategoriaMutation,
  useToggleCategoriaActivaMutation,
} from './useCategoriasQuery'
export type { CategoriaDB } from './useCategoriasQuery'

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
export { usePedidoStatsQuery, EMPTY_PEDIDO_STATS_SUMMARY } from './usePedidoStatsQuery'
export type { PedidoStatsBucket, PedidoStatsSummary } from './usePedidoStatsQuery'

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
  useRegistrarIngresoMutation,
} from './useTransferenciasQuery'

// Métricas
export {
  metricasKeys,
  useMetricasQuery,
  useReportePreventistasQuery,
  useInvalidateMetricas,
} from './useMetricasQuery'

// Promociones
export {
  promocionesKeys,
  usePromoMapQuery,
  usePromocionesListQuery,
  useCrearPromocionMutation,
  useActualizarPromocionMutation,
  useEliminarPromocionMutation,
  useTogglePromocionActivaMutation,
  useAjustarStockPromoMutation,
  usePromoUnidadesEntregadasQuery,
} from './usePromocionesQuery'
export type { PromocionConDetalles, PromocionFormInput } from './usePromocionesQuery'

// Notas de Crédito
export {
  notasCreditoKeys,
  useNotasCreditoByCompraQuery,
  useNotasCreditoResumenQuery,
  useRegistrarNotaCreditoMutation,
} from './useNotasCreditoQuery'
export type { NCResumen } from './useNotasCreditoQuery'

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
  useActualizarPreciosMasivoMutation,
} from './useProductosQuery'
export type { ActualizarPreciosMasivoItem, ActualizarPreciosMasivoResult } from './useProductosQuery'

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
  useQuitarPedidoDeRecorridosMutation,
  useEliminarPedidoMutation,
  usePedidosNoEntregadosQuery,
  usePedidosAsignadosQuery,
  useEntregasMasivasMutation,
  useCancelarPedidoMutation,
  useCambiarClientePedidoMutation,
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
  usePreventistasAsignablesQuery,
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
  useActualizarCompraMutation,
  useAnularCompraMutation,
} from './useComprasQuery'
export type { ActualizarCompraItemsInput } from './useComprasQuery'

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

// Cambios de productos cliente↔depósito
export {
  cambiosProductosKeys,
  useRegistrarCambioProductoMutation,
  useCrearPedidoCambioEnRutaMutation,
  useAplicarCambioParadaMutation,
} from './useCambiosProductosQuery'
export type { RegistrarCambioInput } from './useCambiosProductosQuery'

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
  useRenombrarZonaMutation,
  useEliminarZonaMutation,
  useToggleZonaActivaMutation,
} from './useZonasQuery'
export type { ZonaDB } from './useZonasQuery'

// Depósito de la sucursal (origen/cierre de rutas)
export {
  depositoKeys,
  DEPOSITO_DEFAULT,
  useDepositoCoords,
  useSetDepositoMutation,
  destinoKeys,
  useDestinoCoords,
  useSetDestinoMutation,
} from './useDepositoQuery'
export type { DepositoCoords } from './useDepositoQuery'

// Recorrido activo del transportista (para la ruta real)
export {
  recorridoActivoKeys,
  useRecorridoActivoQuery,
} from './useRecorridoActivoQuery'
export type { RecorridoActivo } from './useRecorridoActivoQuery'

// Recorrido vigente de un transportista+fecha (para editar la ruta del día)
export {
  recorridoExistenteKeys,
  useRecorridoExistenteQuery,
} from './useRecorridoExistenteQuery'
export type { RecorridoExistente } from './useRecorridoExistenteQuery'

// Recorridos de una fecha con paradas completas (para re-descargar la hoja de ruta)
export {
  recorridosHojaRutaKeys,
  useRecorridosHojaRutaQuery,
} from './useRecorridosHojaRutaQuery'
export type { RecorridoHojaRuta } from './useRecorridosHojaRutaQuery'

// Sucursales (el flujo viejo de transferencias fue reemplazado por movimientos)
export {
  sucursalesKeys,
  useSucursalesQuery,
} from './useTransferenciasQuery'

// Movimientos entre sucursales (con aprobación, mig 076)
export {
  movimientosKeys,
  MOVIMIENTOS_PAGE_SIZE,
  useMovimientosQuery,
  useMovimientoItemsQuery,
  useCrearMovimientoMutation,
  useAceptarMovimientoMutation,
  useDenegarMovimientoMutation,
} from './useMovimientosQuery'
export type {
  EstadoMovimiento,
  MovimientoSucursalDB,
  MovimientoItemDB,
  MovimientosFiltros,
  ResolucionItem,
} from './useMovimientosQuery'

// Notificaciones (campanita DB-backed, mig 076)
export {
  useNotificacionesQuery,
  useMarcarNotificacionLeidaMutation,
  useMarcarTodasNotificacionesLeidasMutation,
} from './useNotificacionesQuery'
export type { NotificacionDB } from './useNotificacionesQuery'

// Sustitucion de regalos en promociones (mig 058)
export { useSustituirRegaloMutation } from './useSustituirRegaloMutation'

// Métricas
export {
  metricasKeys,
  useMetricasQuery,
  useReportePreventistasQuery,
  useInvalidateMetricas,
} from './useMetricasQuery'

// Geolocalización de preventistas (panel admin)
export {
  geolocalizacionKeys,
  useGeolocalizacionPreventistasQuery,
} from './useGeolocalizacionPreventistasQuery'
export type {
  GpsStatus,
  UltimaUbicacion,
  PreventistaResumen,
  PedidoConGps,
  VisitaConGps,
  GeolocalizacionPanelData,
} from './useGeolocalizacionPreventistasQuery'

// Visitas (ping de preventista a cliente)
export {
  visitasKeys,
  useVisitasHoyQuery,
  useRegistrarVisitaMutation,
} from './useVisitasQuery'
export type { VisitaHoy, RegistrarVisitaInput } from './useVisitasQuery'

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
  usePromoAcumuladoresMapQuery,
  usePromoAcumuladorQuery,
  usePedidoSustitucionesQuery,
} from './usePromocionesQuery'
export { useSimularSalvedadPromoImpactoQuery } from './useSimularSalvedadQuery'
export type { PromoImpactoSalvedad } from './useSimularSalvedadQuery'
export type { PromocionConDetalles, PromocionFormInput } from './usePromocionesQuery'

// Notas de Crédito
export {
  notasCreditoKeys,
  useNotasCreditoByCompraQuery,
  useNotasCreditoResumenQuery,
  useRegistrarNotaCreditoMutation,
} from './useNotasCreditoQuery'
export type { NCResumen } from './useNotasCreditoQuery'

// Rendicion del dia (helper para pagos masivos)
export {
  rendicionCerradaKeys,
  useRendicionCerradaQuery,
} from './useRendicionCerradaQuery'

// Bot Telegram - Vinculación
export {
  botVinculacionKeys,
  useGenerarCodigoVinculacionBot,
} from './useBotVinculacion'
export type { CodigoVinculacionResult } from './useBotVinculacion'

// Bot Telegram - Vista admin (Phase 4 task 4.2)
export {
  botAdminKeys,
  useBotVinculadosQuery,
  useBotAuditLogQuery,
  useBotAuditSummaryQuery,
  useBotDigestsEnviadosQuery,
  useToggleBotUsuarioMutation,
} from './useBotAdmin'
export type {
  BotVinculado,
  BotAuditEvent,
  BotAuditPorTipo,
  BotAuditPorPerfil,
  BotAuditToolTop,
  BotAuditSummary,
  BotDigestEnviado,
  BotAuditFilters,
  BotToggleUsuarioInput,
  BotToggleUsuarioResult,
} from './useBotAdmin'

// Deudores en mora (cuenta corriente)
export { useDeudoresMoraQuery } from './useDeudoresMoraQuery'
export type { DeudorMora } from './useDeudoresMoraQuery'

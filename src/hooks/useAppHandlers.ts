/**
 * Hook consolidado para los handlers de la aplicación
 *
 * Este archivo compone todos los handlers específicos por dominio:
 * - useClienteHandlers: Operaciones con clientes
 * - useProductoHandlers: Operaciones con productos y mermas
 * - usePedidoHandlers: Operaciones con pedidos
 * - useCompraHandlers: Operaciones con compras
 * - useProveedorHandlers: Operaciones con proveedores
 * - useUsuarioHandlers: Operaciones con usuarios
 *
 * Refactorizado de 766 líneas a ~200 líneas usando composición modular.
 */
import { useCallback, Dispatch, SetStateAction } from 'react'
import type { User } from '@supabase/supabase-js'
import {
  useClienteHandlers,
  useProductoHandlers,
  usePedidoHandlers,
  useCompraHandlers,
  useProveedorHandlers,
  useUsuarioHandlers
} from './handlers'
import type {
  ProductoDB,
  ProveedorDB,
  ClienteDB,
  PedidoDB,
  PerfilDB,
  CompraDB,
  ClienteFormInput,
  ProductoFormInput,
  MermaFormInput,
  CompraFormInput,
  ProveedorFormInput,
  PedidoFormInput,
  FiltrosPedidosState
} from '../types'
import type {
  UseAppStateReturn,
  NuevoPedidoState
} from './useAppState'

// ============================================================================
// TYPES
// ============================================================================

export interface NotifyApi {
  success: (message: string, options?: { persist?: boolean }) => void;
  error: (message: string, duration?: number) => void;
  warning: (message: string) => void;
  info: (message: string) => void;
}

export interface RutaOptimizadaData {
  success?: boolean;
  total_pedidos?: number;
  orden_optimizado?: Array<{
    pedido_id: string;
    orden: number;
    cliente_nombre?: string;
    direccion?: string;
  }>;
  distancia_total?: number;
  duracion_total?: number;
  mensaje?: string;
}

export interface StockValidation {
  valido: boolean;
  errores: Array<{ productoId: string; mensaje: string }>;
}

export interface UseAppHandlersParams {
  // Hooks de datos
  productos: ProductoDB[];
  proveedores: ProveedorDB[];

  // Funciones CRUD Clientes
  agregarCliente: (cliente: ClienteFormInput) => Promise<ClienteDB>;
  actualizarCliente: (id: string, cliente: Partial<ClienteFormInput>) => Promise<ClienteDB>;
  eliminarCliente: (id: string) => Promise<void>;

  // Funciones CRUD Productos
  agregarProducto: (producto: ProductoFormInput) => Promise<ProductoDB>;
  actualizarProducto: (id: string, producto: Partial<ProductoFormInput>) => Promise<ProductoDB>;
  eliminarProducto: (id: string) => Promise<void>;
  validarStock: (items: Array<{ productoId: string; cantidad: number }>) => StockValidation;
  descontarStock: (items: Array<{ productoId?: string; producto_id?: string; cantidad: number }>) => Promise<void>;
  restaurarStock: (items: Array<{ productoId?: string; producto_id?: string; cantidad: number }>) => Promise<void>;

  // Funciones CRUD Pedidos
  crearPedido: (pedido: PedidoFormInput, usuarioId?: string) => Promise<PedidoDB>;
  cambiarEstado: (pedidoId: string, nuevoEstado: string, usuarioId?: string) => Promise<void>;
  asignarTransportista: (pedidoId: string, transportistaId: string | null, usuarioId?: string) => Promise<void>;
  eliminarPedido: (pedidoId: string, usuarioId?: string) => Promise<void>;
  actualizarNotasPedido: (pedidoId: string, notas: string) => Promise<void>;
  actualizarEstadoPago: (pedidoId: string, estadoPago: string, montoPagado?: number) => Promise<void>;
  actualizarFormaPago: (pedidoId: string, formaPago: string) => Promise<void>;
  actualizarOrdenEntrega: (pedidosOrdenados: Array<{ id: string; orden_entrega: number }>) => Promise<void>;
  actualizarItemsPedido: (
    pedidoId: string,
    items: Array<{ producto_id: string; cantidad: number; precio_unitario: number }>,
    usuarioId?: string
  ) => Promise<void>;
  fetchHistorialPedido: (pedidoId: string) => Promise<unknown[]>;

  // Funciones CRUD Usuarios
  actualizarUsuario: (id: string, datos: Partial<PerfilDB>) => Promise<void>;

  // Funciones Pagos
  registrarPago: (params: {
    clienteId: string | number;
    monto: number;
    formaPago: string;
    notas?: string;
    usuarioId?: string;
    pedidoId?: string;
  }) => Promise<unknown>;
  obtenerResumenCuenta: (clienteId: string) => Promise<{ saldo_actual?: number } | null>;

  // Funciones Mermas
  registrarMerma: (merma: MermaFormInput, usuarioId?: string) => Promise<unknown>;

  // Funciones Compras
  registrarCompra: (compra: CompraFormInput, usuarioId?: string) => Promise<CompraDB>;
  anularCompra: (compraId: string) => Promise<void>;

  // Funciones Proveedores
  agregarProveedor: (proveedor: ProveedorFormInput) => Promise<ProveedorDB>;
  actualizarProveedor: (id: string, proveedor: Partial<ProveedorFormInput>) => Promise<ProveedorDB>;

  // Funciones Recorridos
  crearRecorrido: (
    transportistaId: string,
    pedidosIds: string[],
    distancia?: number | null,
    duracion?: number | null
  ) => Promise<unknown>;
  limpiarRuta: () => void;

  // Funciones de refetch
  refetchProductos: () => Promise<void>;
  refetchPedidos: () => Promise<void>;
  refetchMetricas: () => Promise<void>;
  refetchMermas: () => Promise<void>;
  refetchCompras: () => Promise<void>;
  refetchProveedores: () => Promise<void>;

  // Estado de la app
  appState: UseAppStateReturn;

  // Notificaciones
  notify: NotifyApi;

  // Usuario actual
  user: User | null;

  // Ruta optimizada
  rutaOptimizada: RutaOptimizadaData | null;

  // Offline sync
  isOnline: boolean;
  guardarPedidoOffline: (pedido: Partial<NuevoPedidoState> & { total?: number; usuarioId?: string }) => void;
  guardarMermaOffline: (merma: MermaFormInput) => void;
}

export interface UseAppHandlersReturn {
  // Búsqueda y filtros
  handleBusquedaChange: (value: string) => void;
  handleFiltrosChange: (
    nuevosFiltros: Partial<FiltrosPedidosState>,
    filtros: FiltrosPedidosState,
    setFiltros: Dispatch<SetStateAction<FiltrosPedidosState>>
  ) => void;

  // Clientes (from useClienteHandlers)
  handleGuardarCliente: (cliente: ClienteFormInput & { id?: string }) => Promise<void>;
  handleEliminarCliente: (id: string) => void;
  handleVerFichaCliente: (cliente: ClienteDB) => Promise<void>;
  handleAbrirRegistrarPago: (cliente: ClienteDB) => Promise<void>;
  handleRegistrarPago: (datosPago: {
    clienteId: string | number;
    monto: number;
    formaPago: string;
    notas?: string;
  }) => Promise<unknown>;
  handleGenerarReciboPago: (pago: unknown, cliente: ClienteDB) => void;

  // Productos (from useProductoHandlers)
  handleGuardarProducto: (producto: ProductoFormInput & { id?: string }) => Promise<void>;
  handleEliminarProducto: (id: string) => void;
  handleAbrirMerma: (producto: ProductoDB) => void;
  handleRegistrarMerma: (merma: MermaFormInput & { stockNuevo?: number }) => Promise<void>;
  handleVerHistorialMermas: () => void;

  // Usuarios (from useUsuarioHandlers)
  handleGuardarUsuario: (usuario: PerfilDB) => Promise<void>;

  // Pedidos (from usePedidoHandlers)
  agregarItemPedido: (productoId: string) => void;
  actualizarCantidadItem: (productoId: string, cantidad: number) => void;
  handleClienteChange: (clienteId: string) => void;
  handleNotasChange: (notas: string) => void;
  handleFormaPagoChange: (formaPago: string) => void;
  handleEstadoPagoChange: (estadoPago: string) => void;
  handleMontoPagadoChange: (montoPagado: number) => void;
  handleCrearClienteEnPedido: (nuevoCliente: ClienteFormInput) => Promise<ClienteDB>;
  handleGuardarPedidoConOffline: () => Promise<void>;
  handleMarcarEntregado: (pedido: PedidoDB) => void;
  handleDesmarcarEntregado: (pedido: PedidoDB) => void;
  handleMarcarEnPreparacion: (pedido: PedidoDB) => void;
  handleAsignarTransportista: (transportistaId: string | null, marcarListo?: boolean) => Promise<void>;
  handleEliminarPedido: (id: string) => void;
  handleVerHistorial: (pedido: PedidoDB) => Promise<void>;
  handleEditarPedido: (pedido: PedidoDB) => void;
  handleGuardarEdicionPedido: (datos: {
    notas: string;
    formaPago: string;
    estadoPago: string;
    montoPagado?: number;
  }) => Promise<void>;
  handleAplicarOrdenOptimizado: (data: unknown) => Promise<void>;
  handleExportarHojaRutaOptimizada: (transportista: PerfilDB, pedidosOrdenados: PedidoDB[]) => void;
  handleCerrarModalOptimizar: () => void;
  generarOrdenPreparacion: (pedido: PedidoDB) => void;
  generarHojaRuta: (transportista: PerfilDB, pedidos: PedidoDB[]) => void;

  // Compras (from useCompraHandlers)
  handleNuevaCompra: () => void;
  handleRegistrarCompra: (compraData: CompraFormInput) => Promise<void>;
  handleVerDetalleCompra: (compra: CompraDB) => void;
  handleAnularCompra: (compraId: string) => void;

  // Proveedores (from useProveedorHandlers)
  handleNuevoProveedor: () => void;
  handleEditarProveedor: (proveedor: ProveedorDB) => void;
  handleGuardarProveedor: (proveedor: ProveedorFormInput & { id?: string }) => Promise<void>;
  handleToggleActivoProveedor: (proveedor: ProveedorDB) => Promise<void>;
  handleEliminarProveedor: (id: string) => void;
}

// ============================================================================
// HOOK PRINCIPAL
// ============================================================================

export function useAppHandlers({
  // Hooks de datos
  productos,
  proveedores,

  // Funciones CRUD
  agregarCliente,
  actualizarCliente,
  eliminarCliente,
  agregarProducto,
  actualizarProducto,
  eliminarProducto,
  validarStock,
  descontarStock,
  restaurarStock,
  crearPedido,
  cambiarEstado,
  asignarTransportista,
  eliminarPedido,
  actualizarNotasPedido,
  actualizarEstadoPago,
  actualizarFormaPago,
  actualizarOrdenEntrega,
  actualizarItemsPedido,
  fetchHistorialPedido,
  actualizarUsuario,
  registrarPago,
  obtenerResumenCuenta,
  registrarMerma,
  registrarCompra,
  anularCompra,
  agregarProveedor,
  actualizarProveedor,
  crearRecorrido,
  limpiarRuta,

  // Funciones de refetch
  refetchProductos,
  refetchPedidos,
  refetchMetricas,
  refetchMermas,
  refetchCompras,
  refetchProveedores,

  // Estado de la app
  appState,

  // Notificaciones
  notify,

  // Usuario actual
  user,

  // Ruta optimizada
  rutaOptimizada,

  // Offline sync
  isOnline,
  guardarPedidoOffline,
  guardarMermaOffline
}: UseAppHandlersParams): UseAppHandlersReturn {
  const {
    setGuardando,
    setNuevoPedido,
    resetNuevoPedido,
    nuevoPedido,
    setBusqueda,
    setPaginaActual,
    modales,
    setClienteEditando,
    setProductoEditando,
    setUsuarioEditando,
    setPedidoAsignando,
    setPedidoHistorial,
    setHistorialCambios,
    setPedidoEditando,
    setClienteFicha,
    setClientePago,
    setSaldoPendienteCliente,
    setProductoMerma,
    setCompraDetalle,
    setProveedorEditando,
    setCargandoHistorial,
    pedidoAsignando,
    pedidoEditando
  } = appState

  // Handlers de búsqueda y filtros
  const handleBusquedaChange = useCallback((value: string): void => {
    setBusqueda(value)
    setPaginaActual(1)
  }, [setBusqueda, setPaginaActual])

  const handleFiltrosChange = useCallback((
    nuevosFiltros: Partial<FiltrosPedidosState>,
    filtros: FiltrosPedidosState,
    setFiltros: Dispatch<SetStateAction<FiltrosPedidosState>>
  ): void => {
    setFiltros({ ...filtros, ...nuevosFiltros })
    setPaginaActual(1)
  }, [setPaginaActual])

  // Componer handlers por dominio
  const clienteHandlers = useClienteHandlers({
    agregarCliente,
    actualizarCliente,
    eliminarCliente,
    registrarPago,
    obtenerResumenCuenta,
    modales,
    setGuardando,
    setClienteEditando,
    setClienteFicha,
    setClientePago,
    setSaldoPendienteCliente,
    notify,
    user
  })

  const productoHandlers = useProductoHandlers({
    agregarProducto,
    actualizarProducto,
    eliminarProducto,
    registrarMerma,
    modales,
    setGuardando,
    setProductoEditando,
    setProductoMerma,
    refetchProductos,
    refetchMermas,
    notify,
    user,
    isOnline,
    guardarMermaOffline
  })

  const pedidoHandlers = usePedidoHandlers({
    productos,
    crearPedido,
    cambiarEstado,
    asignarTransportista,
    eliminarPedido,
    actualizarNotasPedido,
    actualizarEstadoPago,
    actualizarFormaPago,
    actualizarOrdenEntrega,
    actualizarItemsPedido,
    fetchHistorialPedido,
    validarStock,
    descontarStock,
    restaurarStock,
    registrarPago,
    crearRecorrido,
    limpiarRuta,
    agregarCliente,
    modales,
    setGuardando,
    setNuevoPedido,
    resetNuevoPedido,
    nuevoPedido,
    setPedidoAsignando,
    setPedidoHistorial,
    setHistorialCambios,
    setPedidoEditando,
    setCargandoHistorial,
    pedidoAsignando,
    pedidoEditando,
    refetchProductos,
    refetchPedidos,
    refetchMetricas,
    notify,
    user,
    isOnline,
    guardarPedidoOffline,
    rutaOptimizada
  })

  const compraHandlers = useCompraHandlers({
    registrarCompra,
    anularCompra,
    modales,
    setGuardando,
    setCompraDetalle,
    refetchProductos,
    refetchCompras,
    notify,
    user
  })

  const proveedorHandlers = useProveedorHandlers({
    proveedores,
    agregarProveedor,
    actualizarProveedor,
    modales,
    setGuardando,
    setProveedorEditando,
    refetchProveedores,
    notify
  })

  const usuarioHandlers = useUsuarioHandlers({
    actualizarUsuario,
    modales,
    setGuardando,
    setUsuarioEditando,
    notify
  })

  return {
    // Búsqueda y filtros
    handleBusquedaChange,
    handleFiltrosChange,

    // Clientes
    ...clienteHandlers,

    // Productos
    ...productoHandlers,

    // Usuarios
    ...usuarioHandlers,

    // Pedidos
    ...pedidoHandlers,

    // Compras
    ...compraHandlers,

    // Proveedores
    ...proveedorHandlers
  } as UseAppHandlersReturn
}

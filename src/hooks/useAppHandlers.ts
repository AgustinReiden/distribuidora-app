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
  CompraDBExtended,
  ClienteFormInput,
  ProductoFormInput,
  MermaFormInput,
  CompraFormInput,
  ProveedorFormInput,
  FiltrosPedidosState,
  RutaOptimizada as RutaOptimizadaType
} from '../types'
import type {
  UseAppStateReturn,
  NuevoPedidoState
} from './useAppState'

// ============================================================================
// TYPES
// ============================================================================

/** Notification API interface */
export interface NotifyApi {
  success: (message: string, options?: { persist?: boolean }) => void;
  error: (message: string, duration?: number) => void;
  warning: (message: string) => void;
  info: (message: string) => void;
}

/** Optimized route order item */
export interface OrdenOptimizadoItem {
  pedido_id: string;
  orden: number;
  cliente_nombre?: string;
  direccion?: string;
}

/** Optimized route data - flexible type */
export interface RutaOptimizadaData {
  success?: boolean;
  total_pedidos?: number;
  orden_optimizado?: OrdenOptimizadoItem[];
  distancia_total?: number;
  duracion_total?: number;
  mensaje?: string;
  // Fields from RutaOptimizada type
  pedidos?: PedidoDB[];
  distanciaTotal?: number;
  duracionTotal?: number;
  orden?: string[];
}

/** Stock validation error */
export interface StockValidationError {
  productoId: string;
  mensaje: string;
}

/** Stock validation result */
export interface StockValidation {
  valido: boolean;
  errores: StockValidationError[];
}

/** Stock item for operations */
export interface StockItem {
  productoId?: string;
  producto_id?: string;
  cantidad: number;
}

/** Pedido item for update */
export interface PedidoItemUpdate {
  producto_id: string;
  cantidad: number;
  precio_unitario: number;
}

/** Pedido order update */
export interface PedidoOrdenUpdate {
  id: string;
  orden_entrega: number;
}

/** Payment registration params - flexible to accept different formats */
export interface RegistrarPagoParams {
  clienteId: string | number;
  monto: number | string;
  formaPago?: string;
  notas?: string | null;
  usuarioId?: string | null;
  pedidoId?: string | null;
  referencia?: string | null;
}

/** Account summary - flexible type */
export interface ResumenCuenta {
  saldo_actual?: number;
  limite_credito?: number;
  credito_disponible?: number;
  total_pedidos?: number;
  total_compras?: number;
  total_pagos?: number;
  pedidos_pendientes_pago?: number;
  ultimo_pedido?: string | null;
  ultimo_pago?: string | null;
}

/** Offline pedido data */
export interface PedidoOfflineData extends Partial<NuevoPedidoState> {
  total?: number;
  usuarioId?: string;
}

 
/** Params for useAppHandlers hook - flexible types to match actual hook signatures */
export interface UseAppHandlersParams {
  // Hooks de datos
  clientes?: ClienteDB[];
  pedidos?: PedidoDB[];
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
  descontarStock: (items: StockItem[]) => Promise<void>;
  restaurarStock: (items: StockItem[]) => Promise<void>;

  // Funciones CRUD Pedidos - flexible signatures
  crearPedido: (...args: any[]) => Promise<any>;
  cambiarEstado: (pedidoId: string, nuevoEstado: string, usuarioId?: string) => Promise<void>;
  asignarTransportista: (...args: any[]) => Promise<void>;
  eliminarPedido: (...args: any[]) => Promise<void>;
  actualizarNotasPedido: (pedidoId: string, notas: string) => Promise<void>;
  actualizarEstadoPago: (pedidoId: string, estadoPago: string, montoPagado?: number) => Promise<void>;
  actualizarFormaPago: (pedidoId: string, formaPago: string) => Promise<void>;
  actualizarOrdenEntrega: (...args: any[]) => Promise<void>;
  actualizarItemsPedido: (...args: any[]) => Promise<any>;
  fetchHistorialPedido: (pedidoId: string) => Promise<unknown[]>;

  // Funciones CRUD Usuarios
  actualizarUsuario: (id: string, datos: Partial<PerfilDB>) => Promise<void>;

  // Funciones Pagos - flexible signatures
  registrarPago: (...args: any[]) => Promise<any>;
  obtenerResumenCuenta: (clienteId: string) => Promise<ResumenCuenta | null>;

  // Funciones Mermas - flexible signatures
  registrarMerma: (...args: any[]) => Promise<any>;

  // Funciones Compras - flexible signatures
  registrarCompra: (...args: any[]) => Promise<any>;
  anularCompra: (compraId: string) => Promise<void>;

  // Funciones Proveedores
  agregarProveedor: (proveedor: ProveedorFormInput) => Promise<ProveedorDB>;
  actualizarProveedor: (id: string, proveedor: Partial<ProveedorFormInput>) => Promise<ProveedorDB>;

  // Funciones Recorridos - flexible signatures
  crearRecorrido: (...args: any[]) => Promise<any>;
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
  guardarPedidoOffline: (...args: any[]) => any;
  guardarMermaOffline: (merma: MermaFormInput) => void;
}
 

/** Payment data for handler */
export interface PagoHandlerData {
  clienteId: string | number;
  monto: number;
  formaPago: string;
  notas?: string;
}

/** Edition data for pedido */
export interface EdicionPedidoData {
  notas: string;
  formaPago: string;
  estadoPago: string;
  montoPagado?: number;
}

 
/** Return type for useAppHandlers - flexible types for compatibility */
export interface UseAppHandlersReturn {
  // Búsqueda y filtros
  handleBusquedaChange: (value: string) => void;
  handleFiltrosChange: (...args: any[]) => void;

  // Clientes (from useClienteHandlers)
  handleGuardarCliente: (cliente: any) => Promise<void>;
  handleEliminarCliente: (id: string) => void;
  handleVerFichaCliente: (cliente: ClienteDB) => Promise<void>;
  handleAbrirRegistrarPago: (cliente: ClienteDB, saldo?: number) => Promise<void>;
  handleRegistrarPago: (...args: any[]) => Promise<any>;
  handleGenerarReciboPago: (...args: any[]) => void;

  // Productos (from useProductoHandlers)
  handleGuardarProducto: (producto: any) => Promise<void>;
  handleEliminarProducto: (id: string) => void;
  handleAbrirMerma: (producto: ProductoDB) => void;
  handleRegistrarMerma: (merma: any) => Promise<void>;
  handleVerHistorialMermas: () => void;

  // Usuarios (from useUsuarioHandlers)
  handleGuardarUsuario: (usuario: any) => Promise<void>;

  // Pedidos (from usePedidoHandlers)
  agregarItemPedido: (productoId: string, cantidad?: number, precio?: number) => void;
  actualizarCantidadItem: (productoId: string, cantidad: number) => void;
  handleClienteChange: (clienteId: string) => void;
  handleNotasChange: (notas: string) => void;
  handleFormaPagoChange: (formaPago: string) => void;
  handleEstadoPagoChange: (estadoPago: string) => void;
  handleMontoPagadoChange: (montoPagado: number) => void;
  handleCrearClienteEnPedido: (nuevoCliente: any) => Promise<any>;
  handleGuardarPedidoConOffline: () => Promise<void>;
  handleMarcarEntregado: (pedido: PedidoDB) => void;
  handleDesmarcarEntregado: (pedido: PedidoDB) => void;
  handleMarcarEnPreparacion: (pedido: PedidoDB) => void;
  handleAsignarTransportista: (transportistaId: string | null, marcarListo?: boolean) => Promise<void>;
  handleEliminarPedido: (id: string) => void;
  handleVerHistorial: (pedido: PedidoDB) => Promise<void>;
  handleEditarPedido: (pedido: PedidoDB) => void;
  handleGuardarEdicionPedido: (datos: any) => Promise<void>;
  handleAplicarOrdenOptimizado: (data: any) => Promise<void>;
  handleExportarHojaRutaOptimizada: (...args: any[]) => any;
  handleCerrarModalOptimizar: () => void;
  generarOrdenPreparacion: (pedido: PedidoDB) => void;
  generarHojaRuta: (transportista: PerfilDB, pedidos: PedidoDB[]) => void;

  // Compras (from useCompraHandlers)
  handleNuevaCompra: () => void;
  handleRegistrarCompra: (compraData: any) => Promise<void>;
  handleVerDetalleCompra: (compra: any) => void;
  handleAnularCompra: (compraId: string) => void;

  // Proveedores (from useProveedorHandlers)
  handleNuevoProveedor: () => void;
  handleEditarProveedor: (proveedor: any) => void;
  handleGuardarProveedor: (proveedor: any) => Promise<void>;
  handleToggleActivoProveedor: (proveedor: any) => Promise<void>;
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

  // Componer handlers por dominio - using type assertions for flexibility
   
  const clienteHandlers = useClienteHandlers({
    agregarCliente,
    actualizarCliente,
    eliminarCliente,
    registrarPago: registrarPago as any,
    obtenerResumenCuenta: obtenerResumenCuenta as any,
    modales: modales as any,
    setGuardando,
    setClienteEditando,
    setClienteFicha,
    setClientePago,
    setSaldoPendienteCliente,
    notify: notify as any,
    user
  })

  const productoHandlers = useProductoHandlers({
    agregarProducto,
    actualizarProducto,
    eliminarProducto,
    registrarMerma: registrarMerma as any,
    modales: modales as any,
    setGuardando,
    setProductoEditando,
    setProductoMerma,
    refetchProductos,
    refetchMermas,
    notify: notify as any,
    user,
    isOnline,
    guardarMermaOffline
  })

  const pedidoHandlers = usePedidoHandlers({
    productos,
    crearPedido: crearPedido as any,
    cambiarEstado,
    asignarTransportista: asignarTransportista as any,
    eliminarPedido: eliminarPedido as any,
    actualizarNotasPedido,
    actualizarEstadoPago,
    actualizarFormaPago,
    actualizarOrdenEntrega: actualizarOrdenEntrega as any,
    actualizarItemsPedido: actualizarItemsPedido as any,
    fetchHistorialPedido: fetchHistorialPedido as any,
    validarStock: validarStock as any,
    descontarStock,
    restaurarStock,
    registrarPago: registrarPago as any,
    crearRecorrido: crearRecorrido as any,
    limpiarRuta,
    agregarCliente,
    modales: modales as any,
    setGuardando,
    setNuevoPedido: setNuevoPedido as any,
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
    notify: notify as any,
    user,
    isOnline,
    guardarPedidoOffline: guardarPedidoOffline as any,
    rutaOptimizada: rutaOptimizada as any
  })

  const compraHandlers = useCompraHandlers({
    registrarCompra: registrarCompra as any,
    anularCompra,
    modales: modales as any,
    setGuardando,
    setCompraDetalle: setCompraDetalle as any,
    refetchProductos,
    refetchCompras,
    notify: notify as any,
    user
  })
   

  const proveedorHandlers = useProveedorHandlers({
    proveedores,
    agregarProveedor: agregarProveedor as any,
    actualizarProveedor: actualizarProveedor as any,
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

  // Combine all handlers
  const combinedHandlers = {
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
  }

  return combinedHandlers as unknown as UseAppHandlersReturn
}

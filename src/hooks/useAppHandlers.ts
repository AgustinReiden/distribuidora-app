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
import React, { useCallback, Dispatch, SetStateAction } from 'react'
import type { User } from '@supabase/supabase-js'
import {
  useClienteHandlers,
  useProductoHandlers,
  usePedidoHandlers,
  useCompraHandlers,
  useProveedorHandlers,
  useUsuarioHandlers,
  type UseClienteHandlersProps,
  type UseProductoHandlersProps,
  type UsePedidoHandlersProps
} from './handlers'
import type {
  ProductoDB,
  ProveedorDB,
  ClienteDB,
  PedidoDB,
  PerfilDB,
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
  warning: (message: string, options?: { persist?: boolean }) => void;
  info: (message: string, options?: { persist?: boolean }) => void;
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

  // Funciones CRUD Pedidos
  crearPedido: (
    clienteId: number,
    items: Array<{ productoId: string; cantidad: number; precioUnitario: number }>,
    total: number,
    usuarioId: string,
    descontarStock: (items: Array<{ productoId?: string; producto_id?: string; cantidad: number }>) => Promise<void>,
    notas?: string,
    formaPago?: string,
    estadoPago?: string
  ) => Promise<PedidoDB>;
  cambiarEstado: (pedidoId: string, nuevoEstado: string, usuarioId?: string) => Promise<void>;
  asignarTransportista: (pedidoId: string, transportistaId: string | null, marcarListo?: boolean) => Promise<void>;
  eliminarPedido: (
    pedidoId: string,
    restaurarStock: (items: Array<{ productoId?: string; producto_id?: string; cantidad: number }>) => Promise<void>,
    usuarioId?: string
  ) => Promise<void>;
  actualizarNotasPedido: (pedidoId: string, notas: string) => Promise<void>;
  actualizarEstadoPago: (pedidoId: string, estadoPago: string, montoPagado?: number) => Promise<void>;
  actualizarFormaPago: (pedidoId: string, formaPago: string) => Promise<void>;
  actualizarOrdenEntrega: (pedidosOrdenados: Array<{ id: string; orden_entrega: number }>) => Promise<void>;
  actualizarItemsPedido: (pedidoId: string, items: Array<{ producto_id: string; cantidad: number; precio_unitario: number }>, usuarioId?: string) => Promise<void>;
  fetchHistorialPedido: (pedidoId: string) => Promise<unknown[]>;

  // Funciones CRUD Usuarios
  actualizarUsuario: (id: string, datos: Partial<PerfilDB>) => Promise<void>;

  // Funciones Pagos
  registrarPago: (pago: {
    clienteId: string;
    pedidoId?: string | null;
    monto: number | string;
    formaPago?: string;
    referencia?: string | null;
    notas?: string | null;
    usuarioId?: string | null;
  }) => Promise<{ id: string; cliente_id: string; monto: number; forma_pago: string; created_at?: string }>;
  obtenerResumenCuenta: (clienteId: string) => Promise<ResumenCuenta | null>;

  // Funciones Mermas
  registrarMerma: (mermaData: {
    productoId: string;
    cantidad: number;
    motivo: string;
    observaciones?: string | null;
    stockAnterior: number;
    stockNuevo: number;
    usuarioId?: string | null;
  }) => Promise<{ success: boolean; merma: { id: string } | null }>;

  // Funciones Compras
  registrarCompra: (compraData: {
    proveedorId?: string | null;
    proveedorNombre?: string | null;
    numeroFactura?: string | null;
    fechaCompra?: string;
    subtotal?: number;
    iva?: number;
    otrosImpuestos?: number;
    total?: number;
    formaPago?: string;
    notas?: string | null;
    usuarioId?: string | null;
    items: Array<{ productoId: string; cantidad: number; costoUnitario?: number; subtotal?: number }>;
  }) => Promise<{ success: boolean; compraId: string }>;
  anularCompra: (compraId: string) => Promise<void>;

  // Funciones Proveedores
  agregarProveedor: (proveedor: ProveedorFormInput) => Promise<ProveedorDB>;
  actualizarProveedor: (id: string, proveedor: Partial<ProveedorFormInput>) => Promise<ProveedorDB>;

  // Funciones Recorridos
  crearRecorrido: (
    transportistaId: string,
    pedidosOrdenados: Array<{ id: string; orden_entrega: number }>,
    distancia?: number | null,
    duracion?: number | null
  ) => Promise<string>;
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
  guardarPedidoOffline: (pedido: {
    clienteId: number;
    items: Array<{ productoId: string; cantidad: number; precioUnitario: number }>;
    total: number;
    usuarioId: string;
    notas?: string;
    formaPago?: string;
    estadoPago?: string;
    montoPagado?: number;
  }) => void;
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

 
/** Return type for useAppHandlers */
export interface UseAppHandlersReturn {
  // Búsqueda y filtros
  handleBusquedaChange: (value: string) => void;
  handleFiltrosChange: (
    nuevosFiltros: Partial<FiltrosPedidosState>,
    filtros: FiltrosPedidosState,
    setFiltros: React.Dispatch<React.SetStateAction<FiltrosPedidosState>>
  ) => void;

  // Clientes (from useClienteHandlers)
  handleGuardarCliente: (cliente: ClienteFormInput) => Promise<void>;
  handleEliminarCliente: (id: string) => void;
  handleVerFichaCliente: (cliente: ClienteDB) => Promise<void>;
  handleAbrirRegistrarPago: (cliente: ClienteDB, saldo?: number) => Promise<void>;
  handleRegistrarPago: (pago: { clienteId: string; monto: number; formaPago: string; notas?: string }) => Promise<void>;
  handleGenerarReciboPago: (pago: { clienteId: string; monto: number; fecha: string }) => void;

  // Productos (from useProductoHandlers)
  handleGuardarProducto: (producto: ProductoFormInput) => Promise<void>;
  handleEliminarProducto: (id: string) => void;
  handleAbrirMerma: (producto: ProductoDB) => void;
  handleRegistrarMerma: (merma: MermaFormInput) => Promise<void>;
  handleVerHistorialMermas: () => void;

  // Usuarios (from useUsuarioHandlers)
  handleGuardarUsuario: (usuario: Partial<PerfilDB>) => Promise<void>;

  // Pedidos (from usePedidoHandlers)
  agregarItemPedido: (productoId: string, cantidad?: number, precio?: number) => void;
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
  handleVolverAPendiente: (pedido: PedidoDB) => void;
  handleAsignarTransportista: (transportistaId: string | null, marcarListo?: boolean) => Promise<void>;
  handleEliminarPedido: (id: string) => void;
  handleVerHistorial: (pedido: PedidoDB) => Promise<void>;
  handleEditarPedido: (pedido: PedidoDB) => void;
  handleGuardarEdicionPedido: (datos: { notas: string; formaPago: string; estadoPago: string; montoPagado?: number }) => Promise<void>;
  handleAplicarOrdenOptimizado: (data: { ordenOptimizado?: Array<{ id: string; orden_entrega: number }>; transportistaId?: string | null; distancia?: number | null; duracion?: number | null } | Array<{ id: string; orden_entrega: number }>) => Promise<void>;
  handleExportarHojaRutaOptimizada: (transportista: PerfilDB, pedidosOrdenados: PedidoDB[]) => void;
  handleCerrarModalOptimizar: () => void;
  generarOrdenPreparacion: (pedido: PedidoDB) => void;
  generarHojaRuta: (transportista: PerfilDB, pedidos: PedidoDB[]) => void;

  // Compras (from useCompraHandlers)
  handleNuevaCompra: () => void;
  handleRegistrarCompra: (compraData: CompraFormInput) => Promise<void>;
  handleVerDetalleCompra: (compra: CompraDBExtended) => void;
  handleAnularCompra: (compraId: string) => void;

  // Proveedores (from useProveedorHandlers)
  handleNuevoProveedor: () => void;
  handleEditarProveedor: (proveedor: ProveedorDB) => void;
  handleGuardarProveedor: (proveedor: ProveedorFormInput) => Promise<void>;
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
  // Adaptadores de tipo para compatibilidad entre interfaces
  const clienteModales = {
    cliente: modales.cliente,
    fichaCliente: modales.fichaCliente,
    registrarPago: modales.registrarPago,
    confirm: modales.confirm
  }

  const clienteHandlers = useClienteHandlers({
    agregarCliente,
    actualizarCliente,
    eliminarCliente,
    registrarPago,
    obtenerResumenCuenta: obtenerResumenCuenta as UseClienteHandlersProps['obtenerResumenCuenta'],
    modales: clienteModales,
    setGuardando,
    setClienteEditando,
    setClienteFicha,
    setClientePago,
    setSaldoPendienteCliente,
    notify,
    user
  })

  const productoModales = {
    producto: modales.producto,
    mermaStock: modales.mermaStock,
    historialMermas: modales.historialMermas,
    confirm: modales.confirm
  }

  const productoHandlers = useProductoHandlers({
    agregarProducto,
    actualizarProducto,
    eliminarProducto,
    registrarMerma: registrarMerma as UseProductoHandlersProps['registrarMerma'],
    modales: productoModales,
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

  const pedidoModales = {
    pedido: modales.pedido,
    asignar: modales.asignar,
    historial: modales.historial,
    editarPedido: modales.editarPedido,
    optimizarRuta: modales.optimizarRuta,
    confirm: modales.confirm
  }

  const pedidoHandlers = usePedidoHandlers({
    productos,
    crearPedido: crearPedido as UsePedidoHandlersProps['crearPedido'],
    cambiarEstado,
    asignarTransportista: asignarTransportista as UsePedidoHandlersProps['asignarTransportista'],
    eliminarPedido: eliminarPedido as UsePedidoHandlersProps['eliminarPedido'],
    actualizarNotasPedido,
    actualizarEstadoPago,
    actualizarFormaPago,
    actualizarOrdenEntrega: actualizarOrdenEntrega as UsePedidoHandlersProps['actualizarOrdenEntrega'],
    actualizarItemsPedido: actualizarItemsPedido as UsePedidoHandlersProps['actualizarItemsPedido'],
    fetchHistorialPedido: fetchHistorialPedido as UsePedidoHandlersProps['fetchHistorialPedido'],
    validarStock: validarStock as UsePedidoHandlersProps['validarStock'],
    descontarStock,
    restaurarStock,
    registrarPago: registrarPago as UsePedidoHandlersProps['registrarPago'],
    crearRecorrido: crearRecorrido as UsePedidoHandlersProps['crearRecorrido'],
    limpiarRuta,
    agregarCliente,
    modales: pedidoModales,
    setGuardando,
    setNuevoPedido: setNuevoPedido as UsePedidoHandlersProps['setNuevoPedido'],
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
    guardarPedidoOffline: guardarPedidoOffline as UsePedidoHandlersProps['guardarPedidoOffline'],
    rutaOptimizada: rutaOptimizada as UsePedidoHandlersProps['rutaOptimizada']
  })

  const compraModales = {
    compra: modales.compra,
    detalleCompra: modales.detalleCompra,
    confirm: modales.confirm
  }

  const compraHandlers = useCompraHandlers({
    registrarCompra,
    anularCompra,
    modales: compraModales,
    setGuardando,
    setCompraDetalle,
    refetchProductos,
    refetchCompras,
    notify,
    user
  })

  const proveedorModales = {
    proveedor: modales.proveedor,
    confirm: modales.confirm
  }

  const proveedorHandlers = useProveedorHandlers({
    proveedores,
    agregarProveedor,
    actualizarProveedor,
    modales: proveedorModales,
    setGuardando,
    setProveedorEditando,
    refetchProveedores,
    notify
  })

  const usuarioModales = {
    usuario: modales.usuario,
    confirm: modales.confirm
  }

  const usuarioHandlers = useUsuarioHandlers({
    actualizarUsuario,
    modales: usuarioModales,
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

  return combinedHandlers
}

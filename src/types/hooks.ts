/**
 * Tipos para los hooks de la aplicación
 */

import type { User } from '@supabase/supabase-js'

// =============================================================================
// ENTIDADES DE BASE DE DATOS (formato real)
// =============================================================================

export interface ClienteDB {
  id: string;
  cuit?: string | null;
  razon_social?: string | null;
  nombre_fantasia: string;
  direccion: string;
  latitud?: number | null;
  longitud?: number | null;
  telefono?: string | null;
  email?: string | null;
  contacto?: string | null;
  zona?: string | null;
  horarios_atencion?: string | null;
  rubro?: string | null;
  notas?: string | null;
  limite_credito?: number;
  dias_credito?: number;
  saldo_cuenta?: number;
  activo?: boolean;
  created_at?: string;
  updated_at?: string;
}

export interface ProductoDB {
  id: string;
  codigo?: string | null;
  nombre: string;
  precio: number;
  stock: number;
  stock_minimo?: number;
  categoria?: string | null;
  costo_sin_iva?: number | null;
  costo_con_iva?: number | null;
  impuestos_internos?: number | null;
  precio_sin_iva?: number | null;
  activo?: boolean;
  created_at?: string;
  updated_at?: string;
}

export interface PedidoItemDB {
  id: string;
  pedido_id: string;
  producto_id: string;
  producto?: ProductoDB;
  cantidad: number;
  precio_unitario: number;
  subtotal?: number;
}

export interface PerfilDB {
  id: string;
  nombre: string;
  email: string;
  rol?: 'admin' | 'preventista' | 'transportista' | 'deposito';
  zona?: string;
  activo?: boolean;
}

export interface PedidoDB {
  id: string;
  cliente_id: string;
  cliente?: ClienteDB;
  usuario_id?: string;
  usuario?: PerfilDB | null;
  transportista_id?: string | null;
  transportista?: PerfilDB | null;
  estado: 'pendiente' | 'en_preparacion' | 'preparado' | 'en_camino' | 'entregado' | 'cancelado' | 'asignado';
  estado_pago?: 'pendiente' | 'parcial' | 'pagado';
  forma_pago?: string;
  total: number;
  monto_pagado?: number;
  notas?: string | null;
  orden_entrega?: number | null;
  items?: PedidoItemDB[];
  stock_descontado?: boolean;
  fecha_entrega?: string | null;
  created_at?: string;
  updated_at?: string;
  deleted_at?: string | null;
}

export interface MermaDB {
  id: string;
  producto_id: string;
  producto?: ProductoDB;
  cantidad: number;
  motivo: string;
  tipo?: 'vencimiento' | 'rotura' | 'robo' | 'otro';
  usuario_id?: string;
  created_at?: string;
}

export interface ProveedorDB {
  id: string;
  nombre: string;
  contacto?: string | null;
  telefono?: string | null;
  email?: string | null;
  direccion?: string | null;
  notas?: string | null;
  activo?: boolean;
  created_at?: string;
}

export interface CompraItemDB {
  id: string;
  compra_id: string;
  producto_id: string;
  producto?: ProductoDB;
  cantidad: number;
  precio_unitario: number;
  subtotal?: number;
}

export interface CompraDB {
  id: string;
  proveedor_id: string;
  proveedor?: ProveedorDB;
  usuario_id?: string;
  total: number;
  estado?: 'activa' | 'anulada';
  notas?: string | null;
  items?: CompraItemDB[];
  created_at?: string;
}

export interface RecorridoDB {
  id: string;
  transportista_id: string;
  transportista?: PerfilDB;
  fecha: string;
  pedidos_ids?: string[];
  estado?: string;
  created_at?: string;
}

export interface PagoDB {
  id: string;
  cliente_id: string;
  monto: number;
  forma_pago: string;
  notas?: string | null;
  usuario_id?: string;
  created_at?: string;
}

// =============================================================================
// INPUTS PARA FORMULARIOS
// =============================================================================

export interface ClienteFormInput {
  cuit?: string;
  razonSocial?: string;
  nombreFantasia: string;
  direccion: string;
  latitud?: number | null;
  longitud?: number | null;
  telefono?: string;
  email?: string;
  contacto?: string;
  zona?: string;
  horarios_atencion?: string;
  rubro?: string;
  notas?: string;
  limiteCredito?: string | number;
  diasCredito?: string | number;
}

export interface ProductoFormInput {
  codigo?: string;
  nombre: string;
  precio: number;
  stock: number;
  stock_minimo?: number;
  categoria?: string;
  costo_sin_iva?: number | string;
  costo_con_iva?: number | string;
  impuestos_internos?: number | string;
  precio_sin_iva?: number | string;
}

export interface PedidoFormInput {
  clienteId: string;
  items: Array<{
    productoId: string;
    cantidad: number;
    precioUnitario: number;
  }>;
  notas?: string;
  formaPago?: string;
}

export interface MermaFormInput {
  productoId: string;
  cantidad: number;
  motivo: string;
  tipo?: string;
}

export interface CompraFormInput {
  proveedorId: string;
  items: Array<{
    productoId: string;
    cantidad: number;
    precioUnitario: number;
  }>;
  notas?: string;
}

export interface ProveedorFormInput {
  nombre: string;
  contacto?: string;
  telefono?: string;
  email?: string;
  direccion?: string;
  notas?: string;
}

// =============================================================================
// FILTROS
// =============================================================================

export interface FiltrosPedidosState {
  fechaDesde: string | null;
  fechaHasta: string | null;
  estado: string;
  estadoPago: string;
  transportistaId: string;
  busqueda: string;
}

// =============================================================================
// RETURN TYPES DE HOOKS
// =============================================================================

export interface UseClientesReturn {
  clientes: ClienteDB[];
  loading: boolean;
  agregarCliente: (cliente: ClienteFormInput) => Promise<ClienteDB>;
  actualizarCliente: (id: string, cliente: Partial<ClienteFormInput>) => Promise<ClienteDB>;
  eliminarCliente: (id: string) => Promise<void>;
  buscarClientes: (termino: string) => Promise<ClienteDB[]>;
  getClientesPorZona: (zona: string) => Promise<ClienteDB[]>;
  getResumenCuenta: (clienteId: string) => Promise<unknown>;
  refetch: () => Promise<void>;
}

export interface UseProductosReturn {
  productos: ProductoDB[];
  loading: boolean;
  agregarProducto: (producto: ProductoFormInput) => Promise<ProductoDB>;
  actualizarProducto: (id: string, producto: Partial<ProductoFormInput>) => Promise<ProductoDB>;
  eliminarProducto: (id: string) => Promise<void>;
  validarStock: (items: Array<{ productoId: string; cantidad: number }>) => { valido: boolean; errores: Array<{ productoId: string; mensaje: string }> };
  descontarStock: (items: Array<{ productoId?: string; producto_id?: string; cantidad: number }>) => Promise<void>;
  restaurarStock: (items: Array<{ productoId?: string; producto_id?: string; cantidad: number }>) => Promise<void>;
  actualizarPreciosMasivo: (productos: Array<{ productoId: string; precioNeto?: number; impInternos?: number; precioFinal?: number }>) => Promise<{ success: boolean; actualizados: number; errores: string[] }>;
  refetch: () => Promise<void>;
}

export interface UsePedidosReturn {
  pedidos: PedidoDB[];
  pedidosFiltrados: () => PedidoDB[];
  loading: boolean;
  filtros: FiltrosPedidosState;
  setFiltros: React.Dispatch<React.SetStateAction<FiltrosPedidosState>>;
  crearPedido: (pedido: PedidoFormInput, usuarioId?: string) => Promise<PedidoDB>;
  cambiarEstado: (pedidoId: string, nuevoEstado: string, usuarioId?: string) => Promise<void>;
  asignarTransportista: (pedidoId: string, transportistaId: string, usuarioId?: string) => Promise<void>;
  eliminarPedido: (pedidoId: string, usuarioId?: string) => Promise<void>;
  actualizarNotasPedido: (pedidoId: string, notas: string) => Promise<void>;
  actualizarEstadoPago: (pedidoId: string, estadoPago: string, montoPagado?: number) => Promise<void>;
  actualizarFormaPago: (pedidoId: string, formaPago: string) => Promise<void>;
  actualizarOrdenEntrega: (pedidosOrdenados: Array<{ id: string; orden_entrega: number }>) => Promise<void>;
  actualizarItemsPedido: (pedidoId: string, items: Array<{ producto_id: string; cantidad: number; precio_unitario: number }>, usuarioId?: string) => Promise<void>;
  fetchHistorialPedido: (pedidoId: string) => Promise<unknown[]>;
  fetchPedidosEliminados: () => Promise<PedidoDB[]>;
  refetch: () => Promise<void>;
}

export interface UseUsuariosReturn {
  usuarios: PerfilDB[];
  transportistas: PerfilDB[];
  loading: boolean;
  actualizarUsuario: (id: string, datos: Partial<PerfilDB>) => Promise<void>;
  refetch: () => Promise<void>;
}

export interface DashboardMetricas {
  pedidosHoy: number;
  pedidosPendientes: number;
  pedidosEntregados: number;
  ventasHoy: number;
  ventasMes: number;
  clientesActivos: number;
  productosStockBajo: number;
  pedidosPorEstado: Record<string, number>;
  ventasPorDia: Array<{ fecha: string; total: number }>;
}

export interface UseDashboardReturn {
  metricas: DashboardMetricas | null;
  reportePreventistas: unknown[];
  reporteInicializado: boolean;
  loading: boolean;
  loadingReporte: boolean;
  filtroPeriodo: string;
  calcularReportePreventistas: () => Promise<void>;
  cambiarPeriodo: (periodo: string) => void;
  refetch: () => Promise<void>;
}

export interface UseBackupReturn {
  exportando: boolean;
  descargarJSON: () => Promise<void>;
  exportarPedidosExcel: (pedidos: PedidoDB[], filtros: unknown, transportistas: PerfilDB[]) => Promise<void>;
}

export interface UsePagosReturn {
  registrarPago: (clienteId: string, monto: number, formaPago: string, notas?: string) => Promise<PagoDB>;
  obtenerResumenCuenta: (clienteId: string) => Promise<unknown>;
}

export interface UseMermasReturn {
  mermas: MermaDB[];
  loading: boolean;
  registrarMerma: (merma: MermaFormInput, usuarioId?: string) => Promise<MermaDB>;
  refetch: () => Promise<void>;
}

export interface UseComprasReturn {
  compras: CompraDB[];
  proveedores: ProveedorDB[];
  loading: boolean;
  registrarCompra: (compra: CompraFormInput, usuarioId?: string) => Promise<CompraDB>;
  anularCompra: (compraId: string) => Promise<void>;
  agregarProveedor: (proveedor: ProveedorFormInput) => Promise<ProveedorDB>;
  actualizarProveedor: (id: string, proveedor: Partial<ProveedorFormInput>) => Promise<ProveedorDB>;
  refetch: () => Promise<void>;
  refetchProveedores: () => Promise<void>;
}

export interface UseRecorridosReturn {
  recorridos: RecorridoDB[];
  loading: boolean;
  fetchRecorridosHoy: () => Promise<void>;
  fetchRecorridosPorFecha: (fecha: string) => Promise<void>;
  crearRecorrido: (transportistaId: string, pedidosIds: string[]) => Promise<RecorridoDB>;
}

export interface RutaOptimizada {
  pedidos: PedidoDB[];
  distanciaTotal: number;
  duracionTotal: number;
  orden: string[];
}

export interface UseOptimizarRutaReturn {
  loading: boolean;
  rutaOptimizada: RutaOptimizada | null;
  error: string | null;
  optimizarRuta: (transportistaId: string, pedidos: PedidoDB[]) => Promise<RutaOptimizada | null>;
  limpiarRuta: () => void;
}

export interface PedidoOffline {
  id: string;
  data: PedidoFormInput;
  timestamp: number;
}

export interface MermaOffline {
  id: string;
  data: MermaFormInput;
  timestamp: number;
}

export interface UseOfflineSyncReturn {
  isOnline: boolean;
  pedidosPendientes: PedidoOffline[];
  mermasPendientes: MermaOffline[];
  sincronizando: boolean;
  guardarPedidoOffline: (pedido: PedidoFormInput) => void;
  guardarMermaOffline: (merma: MermaFormInput) => void;
  sincronizarPedidos: (crearPedido: UsePedidosReturn['crearPedido'], descontarStock: UseProductosReturn['descontarStock']) => Promise<{ sincronizados: number; errores: string[] }>;
  sincronizarMermas: (registrarMerma: UseMermasReturn['registrarMerma']) => Promise<{ sincronizados: number; errores: string[] }>;
}

// =============================================================================
// APP STATE
// =============================================================================

export interface ModalState<T = unknown> {
  open: boolean;
  setOpen: (open: boolean) => void;
  data?: T;
}

export interface AppModalesState {
  pedido: ModalState;
  cliente: ModalState;
  producto: ModalState;
  usuario: ModalState;
  asignar: ModalState;
  historial: ModalState;
  editarPedido: ModalState;
  exportarPDF: ModalState;
  optimizarRuta: ModalState;
  fichaCliente: ModalState;
  merma: ModalState;
  historialMermas: ModalState;
  importarPrecios: ModalState;
  compra: ModalState;
  detalleCompra: ModalState;
  proveedor: ModalState;
  filtroFecha: ModalState;
  pedidosEliminados: ModalState;
  registrarPago: ModalState;
}

export interface AppState {
  vista: string;
  setVista: (vista: string) => void;
  fechaRecorridos: string;
  setFechaRecorridos: (fecha: string) => void;
  modales: AppModalesState;
  guardando: boolean;
  setGuardando: (guardando: boolean) => void;
  cargandoHistorial: boolean;
  setCargandoHistorial: (cargando: boolean) => void;
  busqueda: string;
  setBusqueda: (busqueda: string) => void;
  paginaActual: number;
  setPaginaActual: (pagina: number) => void;
  // Estados de edición
  clienteEditando: ClienteDB | null;
  setClienteEditando: (cliente: ClienteDB | null) => void;
  productoEditando: ProductoDB | null;
  setProductoEditando: (producto: ProductoDB | null) => void;
  pedidoEditando: PedidoDB | null;
  setPedidoEditando: (pedido: PedidoDB | null) => void;
  usuarioEditando: PerfilDB | null;
  setUsuarioEditando: (usuario: PerfilDB | null) => void;
  pedidoAsignando: PedidoDB | null;
  setPedidoAsignando: (pedido: PedidoDB | null) => void;
  historialPedido: unknown[];
  setHistorialPedido: (historial: unknown[]) => void;
  clienteFicha: ClienteDB | null;
  setClienteFicha: (cliente: ClienteDB | null) => void;
  productoMerma: ProductoDB | null;
  setProductoMerma: (producto: ProductoDB | null) => void;
  compraDetalle: CompraDB | null;
  setCompraDetalle: (compra: CompraDB | null) => void;
  proveedorEditando: ProveedorDB | null;
  setProveedorEditando: (proveedor: ProveedorDB | null) => void;
  // Nuevo pedido
  nuevoPedido: {
    clienteId: string;
    items: Array<{ productoId: string; cantidad: number; precioUnitario: number }>;
    notas: string;
  };
  setNuevoPedido: React.Dispatch<React.SetStateAction<AppState['nuevoPedido']>>;
  // Estadísticas
  estadisticasRecorridos: unknown;
}

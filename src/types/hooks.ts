/**
 * Tipos para los hooks de la aplicación
 */

import type { Dispatch, SetStateAction } from 'react'

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

export interface PedidoSalvedadResumen {
  id: string;
  motivo: string;
  cantidad_afectada: number;
  monto_afectado: number;
  estado_resolucion: string;
  producto_id: string;
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
  salvedades?: PedidoSalvedadResumen[];
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
  conSalvedad: 'todos' | 'con_salvedad' | 'sin_salvedad';
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
  setFiltros: Dispatch<SetStateAction<FiltrosPedidosState>>;
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
  setNuevoPedido: Dispatch<SetStateAction<AppState['nuevoPedido']>>;
  // Estadísticas
  estadisticasRecorridos: unknown;
}

// =============================================================================
// DASHBOARD TYPES
// =============================================================================

export interface ProductoVendido {
  id: string;
  nombre: string;
  cantidad: number;
}

export interface ClienteActivo {
  id: string;
  nombre: string;
  total: number;
  pedidos: number;
}

export interface VentaPorDia {
  dia: string;
  ventas: number;
  pedidos: number;
}

export interface PedidosPorEstado {
  pendiente: number;
  en_preparacion: number;
  asignado: number;
  entregado: number;
}

export interface DashboardMetricasExtended {
  ventasPeriodo: number;
  pedidosPeriodo: number;
  ventasPeriodoAnterior?: number | null;
  pedidosPeriodoAnterior?: number | null;
  productosMasVendidos: ProductoVendido[];
  clientesMasActivos: ClienteActivo[];
  pedidosPorEstado: PedidosPorEstado;
  ventasPorDia: VentaPorDia[];
}

export interface ReportePreventista {
  id: string;
  nombre: string;
  email: string;
  totalVentas: number;
  cantidadPedidos: number;
  pedidosPendientes: number;
  pedidosAsignados: number;
  pedidosEntregados: number;
  totalPagado: number;
  totalPendiente: number;
}

export type FiltroPeriodo = 'hoy' | 'semana' | 'mes' | 'anio' | 'personalizado' | 'historico';

export interface UseDashboardReturnExtended {
  metricas: DashboardMetricasExtended;
  loading: boolean;
  loadingReporte: boolean;
  reportePreventistas: ReportePreventista[];
  reporteInicializado: boolean;
  calcularReportePreventistas: (fechaDesde?: string | null, fechaHasta?: string | null) => Promise<void>;
  refetch: (periodo?: FiltroPeriodo, fDesde?: string | null, fHasta?: string | null) => Promise<void>;
  filtroPeriodo: string;
  cambiarPeriodo: (nuevoPeriodo: string, fDesde?: string | null, fHasta?: string | null) => void;
}

// =============================================================================
// BACKUP TYPES
// =============================================================================

export interface BackupData {
  fecha: string;
  tipo: string;
  clientes?: ClienteDB[];
  productos?: ProductoDB[];
  pedidos?: PedidoDB[];
}

export interface FiltrosExportacion {
  estado?: string;
  estadoPago?: string;
  transportistaId?: string;
  fechaDesde?: string;
  fechaHasta?: string;
  busqueda?: string;
}

export interface UseBackupReturnExtended {
  exportando: boolean;
  exportarDatos: (tipo?: string) => Promise<BackupData>;
  descargarJSON: (tipo?: string) => Promise<void>;
  exportarPedidosExcel: (
    pedidos: PedidoDB[],
    filtrosActivos?: FiltrosExportacion,
    transportistas?: PerfilDB[]
  ) => Promise<void>;
}

// =============================================================================
// PAGOS TYPES
// =============================================================================

export interface PagoDBWithUsuario extends PagoDB {
  usuario?: {
    id: string;
    nombre: string;
  } | null;
  referencia?: string | null;
  pedido_id?: string | null;
}

export interface PagoFormInput {
  clienteId: string;
  pedidoId?: string | null;
  monto: number | string;
  formaPago?: string;
  referencia?: string | null;
  notas?: string | null;
  usuarioId?: string | null;
}

export interface ResumenCuenta {
  saldo_actual: number;
  limite_credito: number;
  credito_disponible: number;
  total_pedidos: number;
  total_compras: number;
  total_pagos: number;
  pedidos_pendientes_pago: number;
  ultimo_pedido: string | null;
  ultimo_pago: string | null;
}

export interface UsePagosReturnExtended {
  pagos: PagoDBWithUsuario[];
  loading: boolean;
  fetchPagosCliente: (clienteId: string) => Promise<PagoDBWithUsuario[]>;
  registrarPago: (pago: PagoFormInput) => Promise<PagoDBWithUsuario>;
  eliminarPago: (pagoId: string) => Promise<void>;
  obtenerResumenCuenta: (clienteId: string) => Promise<ResumenCuenta | null>;
}

// =============================================================================
// MERMAS TYPES
// =============================================================================

export interface MermaDBExtended {
  id: string;
  producto_id: string;
  cantidad: number;
  motivo: string;
  observaciones?: string | null;
  stock_anterior: number;
  stock_nuevo: number;
  usuario_id?: string | null;
  created_at?: string;
}

export interface MermaFormInputExtended {
  productoId: string;
  cantidad: number;
  motivo: string;
  observaciones?: string | null;
  stockAnterior: number;
  stockNuevo: number;
  usuarioId?: string | null;
}

export interface MermaRegistroResult {
  success: boolean;
  merma: MermaDBExtended | null;
  soloStock?: boolean;
}

export interface ResumenMermasPorMotivo {
  cantidad: number;
  registros: number;
}

export interface ResumenMermas {
  totalUnidades: number;
  totalRegistros: number;
  porMotivo: Record<string, ResumenMermasPorMotivo>;
}

export interface UseMermasReturnExtended {
  mermas: MermaDBExtended[];
  loading: boolean;
  registrarMerma: (mermaData: MermaFormInputExtended) => Promise<MermaRegistroResult>;
  getMermasPorProducto: (productoId: string) => MermaDBExtended[];
  getResumenMermas: (fechaDesde?: string | null, fechaHasta?: string | null) => ResumenMermas;
  refetch: () => Promise<void>;
}

// =============================================================================
// COMPRAS TYPES
// =============================================================================

export interface ProveedorDBExtended {
  id: string;
  nombre: string;
  cuit?: string | null;
  direccion?: string | null;
  latitud?: number | null;
  longitud?: number | null;
  telefono?: string | null;
  email?: string | null;
  contacto?: string | null;
  notas?: string | null;
  activo?: boolean;
  created_at?: string;
}

export interface CompraItemDBExtended {
  id: string;
  compra_id: string;
  producto_id: string;
  producto?: ProductoDB | null;
  cantidad: number;
  costo_unitario: number;
  subtotal?: number;
}

export interface CompraDBExtended {
  id: string;
  proveedor_id?: string | null;
  proveedor?: ProveedorDBExtended | null;
  proveedor_nombre?: string | null;
  usuario_id?: string | null;
  usuario?: { id: string; nombre: string } | null;
  numero_factura?: string | null;
  fecha_compra?: string;
  subtotal?: number;
  iva?: number;
  otros_impuestos?: number;
  total: number;
  forma_pago?: string;
  estado?: 'activa' | 'cancelada';
  notas?: string | null;
  items?: CompraItemDBExtended[];
  created_at?: string;
}

export interface CompraFormInputExtended {
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
  items: Array<{
    productoId: string;
    cantidad: number;
    costoUnitario?: number;
    subtotal?: number;
  }>;
}

export interface ProveedorFormInputExtended {
  nombre: string;
  cuit?: string | null;
  direccion?: string | null;
  latitud?: number | null;
  longitud?: number | null;
  telefono?: string | null;
  email?: string | null;
  contacto?: string | null;
  notas?: string | null;
  activo?: boolean;
}

export interface ResumenComprasPorProveedor {
  total: number;
  compras: number;
  unidades: number;
}

export interface ResumenCompras {
  totalMonto: number;
  totalCompras: number;
  totalUnidades: number;
  porProveedor: Record<string, ResumenComprasPorProveedor>;
}

export interface RegistrarCompraResult {
  success: boolean;
  compraId: string;
}

export interface UseComprasReturnExtended {
  compras: CompraDBExtended[];
  proveedores: ProveedorDBExtended[];
  loading: boolean;
  registrarCompra: (compraData: CompraFormInputExtended) => Promise<RegistrarCompraResult>;
  agregarProveedor: (proveedor: ProveedorFormInputExtended) => Promise<ProveedorDBExtended>;
  actualizarProveedor: (id: string, proveedor: ProveedorFormInputExtended) => Promise<ProveedorDBExtended>;
  getComprasPorProducto: (productoId: string) => CompraDBExtended[];
  getResumenCompras: (fechaDesde?: string | null, fechaHasta?: string | null) => ResumenCompras;
  anularCompra: (compraId: string) => Promise<void>;
  refetch: () => Promise<void>;
  refetchProveedores: () => Promise<void>;
}

// =============================================================================
// RECORRIDOS TYPES
// =============================================================================

export interface TransportistaBasic {
  id: string;
  nombre: string;
}

export interface RecorridoDBExtended {
  id: string;
  transportista_id: string;
  transportista?: TransportistaBasic | null;
  fecha: string;
  pedidos_json?: Array<{ pedido_id: string; orden_entrega: number }>;
  estado?: string;
  total_pedidos?: number;
  pedidos_entregados?: number;
  total_facturado?: number;
  total_cobrado?: number;
  distancia_total?: number;
  duracion_total?: number;
  completed_at?: string | null;
  created_at?: string;
}

export interface PedidoOrdenado {
  pedido_id?: string;
  id?: string;
  orden?: number;
}

export interface EstadisticaTransportista {
  transportista: TransportistaBasic | null;
  recorridos: number;
  pedidosTotales: number;
  pedidosEntregados: number;
  totalFacturado: number;
  totalCobrado: number;
  distanciaTotal: number;
}

export interface EstadisticasRecorridos {
  total: number;
  porTransportista: EstadisticaTransportista[];
}

export interface UseRecorridosReturnExtended {
  recorridos: RecorridoDBExtended[];
  recorridoActual: { id: string } | null;
  loading: boolean;
  fetchRecorridosHoy: () => Promise<RecorridoDBExtended[]>;
  fetchRecorridosPorFecha: (fecha: string) => Promise<RecorridoDBExtended[]>;
  crearRecorrido: (
    transportistaId: string,
    pedidosOrdenados: PedidoOrdenado[],
    distancia?: number | null,
    duracion?: number | null
  ) => Promise<string>;
  completarRecorrido: (recorridoId: string) => Promise<void>;
  getEstadisticasRecorridos: (fechaDesde: string, fechaHasta: string) => Promise<EstadisticasRecorridos>;
}

// =============================================================================
// FICHA CLIENTE TYPES
// =============================================================================

export interface PedidoClienteWithItems extends PedidoDB {
  items?: Array<PedidoItemDB & { producto?: ProductoDB }>;
}

export interface ProductoFavorito {
  nombre: string;
  cantidad: number;
  veces: number;
}

export interface EstadisticasCliente {
  totalPedidos: number;
  totalCompras: number;
  pedidosPagados: number;
  montoPagado: number;
  pedidosPendientes: number;
  montoPendiente: number;
  ticketPromedio: number;
  frecuenciaCompra: number;
  diasDesdeUltimoPedido: number | null;
  productosFavoritos: ProductoFavorito[];
}

export interface UseFichaClienteReturn {
  pedidosCliente: PedidoClienteWithItems[];
  estadisticas: EstadisticasCliente | null;
  loading: boolean;
  refetch: () => Promise<void>;
}

// =============================================================================
// REPORTES FINANCIEROS TYPES
// =============================================================================

export interface AgingDeuda {
  corriente: number;
  vencido30: number;
  vencido60: number;
  vencido90: number;
}

export interface ReporteCuentaPorCobrar {
  cliente: ClienteDB;
  totalDeuda: number;
  totalPagado: number;
  saldoPendiente: number;
  limiteCredito: number;
  creditoDisponible: number;
  aging: AgingDeuda;
  pedidosPendientes: number;
}

export interface ProductoRentabilidad {
  id: string;
  nombre: string;
  codigo?: string | null;
  cantidadVendida: number;
  ingresos: number;
  costos: number;
  margen: number;
  margenPorcentaje: number;
}

export interface TotalesRentabilidad {
  ingresosTotales: number;
  costosTotales: number;
  margenTotal: number;
  cantidadPedidos: number;
  margenPorcentaje: number;
}

export interface ReporteRentabilidad {
  productos: ProductoRentabilidad[];
  totales: TotalesRentabilidad;
}

export interface VentaPorCliente {
  cliente: ClienteDB | null;
  cantidadPedidos: number;
  totalVentas: number;
  pedidosPagados: number;
  pedidosPendientes: number;
}

export interface VentaPorZona {
  zona: string;
  cantidadPedidos: number;
  totalVentas: number;
  cantidadClientes: number;
  ticketPromedio: number;
}

export interface UseReportesFinancierosReturn {
  loading: boolean;
  generarReporteCuentasPorCobrar: () => Promise<ReporteCuentaPorCobrar[]>;
  generarReporteRentabilidad: (fechaDesde?: string | null, fechaHasta?: string | null) => Promise<ReporteRentabilidad>;
  generarReporteVentasPorCliente: (fechaDesde?: string | null, fechaHasta?: string | null) => Promise<VentaPorCliente[]>;
  generarReporteVentasPorZona: (fechaDesde?: string | null, fechaHasta?: string | null) => Promise<VentaPorZona[]>;
}

// =============================================================================
// RENDICIONES TYPES
// =============================================================================

export type EstadoRendicion = 'pendiente' | 'presentada' | 'aprobada' | 'rechazada' | 'con_observaciones';

export type TipoAjusteRendicion = 'faltante' | 'sobrante' | 'vuelto_no_dado' | 'error_cobro' | 'descuento_autorizado' | 'otro';

export interface RendicionDB {
  id: string;
  recorrido_id: string;
  transportista_id: string;
  fecha: string;
  total_efectivo_esperado: number;
  total_otros_medios: number;
  monto_rendido: number;
  diferencia: number;
  estado: EstadoRendicion;
  justificacion_transportista?: string | null;
  observaciones_admin?: string | null;
  presentada_at?: string | null;
  revisada_at?: string | null;
  revisada_por?: string | null;
  created_at?: string;
  updated_at?: string;
}

export interface RendicionItemDB {
  id: string;
  rendicion_id: string;
  pedido_id: string;
  monto_cobrado: number;
  forma_pago: string;
  referencia?: string | null;
  incluido_en_rendicion: boolean;
  notas?: string | null;
  created_at?: string;
  pedido?: PedidoDB;
}

export interface RendicionAjusteDB {
  id: string;
  rendicion_id: string;
  tipo: TipoAjusteRendicion;
  monto: number;
  descripcion: string;
  foto_url?: string | null;
  aprobado?: boolean | null;
  aprobado_por?: string | null;
  aprobado_at?: string | null;
  created_at?: string;
}

export interface RendicionDBExtended extends RendicionDB {
  transportista?: PerfilDB | null;
  revisada_por_perfil?: PerfilDB | null;
  recorrido?: RecorridoDBExtended | null;
  items?: RendicionItemDB[];
  ajustes?: RendicionAjusteDB[];
  total_pedidos?: number;
  pedidos_entregados?: number;
  total_facturado?: number;
  total_cobrado?: number;
  total_ajustes?: number;
}

export interface RendicionAjusteInput {
  tipo: TipoAjusteRendicion;
  monto: number;
  descripcion: string;
  foto?: File | null;
}

export interface PresentarRendicionInput {
  rendicionId: string;
  montoRendido: number;
  justificacion?: string | null;
  ajustes?: RendicionAjusteInput[];
}

export interface RevisarRendicionInput {
  rendicionId: string;
  accion: 'aprobar' | 'rechazar' | 'observar';
  observaciones?: string | null;
}

export interface EstadisticasRendiciones {
  total: number;
  pendientes: number;
  aprobadas: number;
  rechazadas: number;
  con_observaciones: number;
  total_efectivo_esperado: number;
  total_rendido: number;
  total_diferencias: number;
  por_transportista?: Array<{
    transportista_id: string;
    transportista_nombre: string;
    rendiciones: number;
    total_rendido: number;
    total_diferencias: number;
  }>;
}

export interface UseRendicionesReturn {
  rendiciones: RendicionDBExtended[];
  rendicionActual: RendicionDBExtended | null;
  loading: boolean;
  // Crear y presentar (transportista o admin)
  crearRendicion: (recorridoId: string, transportistaId?: string) => Promise<string>;
  presentarRendicion: (input: PresentarRendicionInput) => Promise<{ success: boolean; diferencia: number }>;
  agregarAjuste: (rendicionId: string, ajuste: RendicionAjusteInput) => Promise<void>;
  // Admin
  revisarRendicion: (input: RevisarRendicionInput) => Promise<{ success: boolean; nuevoEstado: EstadoRendicion }>;
  // Consultas
  fetchRendicionActual: (transportistaId: string) => Promise<RendicionDBExtended | null>;
  fetchRendicionesPorFecha: (fecha: string) => Promise<RendicionDBExtended[]>;
  fetchRendicionesPorTransportista: (transportistaId: string, desde?: string, hasta?: string) => Promise<RendicionDBExtended[]>;
  fetchRendicionById: (id: string) => Promise<RendicionDBExtended | null>;
  getEstadisticas: (desde?: string, hasta?: string, transportistaId?: string) => Promise<EstadisticasRendiciones>;
  refetch: () => Promise<void>;
}

// =============================================================================
// SALVEDADES TYPES
// =============================================================================

export type MotivoSalvedad =
  | 'faltante_stock'
  | 'producto_danado'
  | 'cliente_rechaza'
  | 'error_pedido'
  | 'producto_vencido'
  | 'diferencia_precio'
  | 'otro';

export type EstadoResolucionSalvedad =
  | 'pendiente'
  | 'reprogramada'
  | 'nota_credito'
  | 'descuento_transportista'
  | 'absorcion_empresa'
  | 'resuelto_otro'
  | 'anulada';

export interface SalvedadItemDB {
  id: string;
  pedido_id: string;
  pedido_item_id: string;
  producto_id: string;
  cantidad_original: number;
  cantidad_afectada: number;
  cantidad_entregada: number;
  motivo: MotivoSalvedad;
  descripcion?: string | null;
  foto_url?: string | null;
  monto_afectado: number;
  precio_unitario: number;
  estado_resolucion: EstadoResolucionSalvedad;
  resolucion_notas?: string | null;
  resolucion_fecha?: string | null;
  resuelto_por?: string | null;
  stock_devuelto: boolean;
  stock_devuelto_at?: string | null;
  pedido_reprogramado_id?: string | null;
  reportado_por: string;
  created_at?: string;
  updated_at?: string;
}

export interface SalvedadHistorialDB {
  id: string;
  salvedad_id: string;
  accion: string;
  estado_anterior?: string | null;
  estado_nuevo?: string | null;
  notas?: string | null;
  usuario_id?: string | null;
  created_at?: string;
}

export interface SalvedadItemDBExtended extends SalvedadItemDB {
  producto?: ProductoDB | null;
  producto_nombre?: string;
  producto_codigo?: string | null;
  pedido?: PedidoDB | null;
  cliente_id?: string;
  cliente_nombre?: string;
  transportista_id?: string | null;
  transportista_nombre?: string | null;
  pedido_estado?: string;
  pedido_total?: number;
  reportado_por_nombre?: string;
  resuelto_por_nombre?: string | null;
  historial?: SalvedadHistorialDB[];
}

export interface RegistrarSalvedadInput {
  pedidoId: string;
  pedidoItemId: string;
  cantidadAfectada: number;
  motivo: MotivoSalvedad;
  descripcion?: string | null;
  fotoUrl?: string | null;
  devolverStock?: boolean;
}

export interface RegistrarSalvedadResult {
  success: boolean;
  error?: string;
  salvedad_id?: string;
  monto_afectado?: number;
  cantidad_entregada?: number;
  stock_devuelto?: boolean;
  nuevo_total_pedido?: number;
}

export interface ResolverSalvedadInput {
  salvedadId: string;
  estadoResolucion: Exclude<EstadoResolucionSalvedad, 'pendiente'>;
  notas?: string | null;
  pedidoReprogramadoId?: string | null;
}

export interface EstadisticasSalvedades {
  total: number;
  pendientes: number;
  resueltas: number;
  anuladas: number;
  monto_total_afectado: number;
  monto_pendiente: number;
  por_motivo?: Record<MotivoSalvedad, number>;
  por_resolucion?: Record<EstadoResolucionSalvedad, number>;
  por_producto?: Array<{
    producto_id: string;
    producto_nombre: string;
    cantidad: number;
    monto: number;
    unidades_afectadas: number;
  }>;
  por_transportista?: Array<{
    transportista_id: string;
    transportista_nombre: string;
    cantidad: number;
    monto: number;
  }>;
}

export interface UseSalvedadesReturn {
  salvedades: SalvedadItemDBExtended[];
  loading: boolean;
  // Transportista o admin puede registrar
  registrarSalvedad: (input: RegistrarSalvedadInput) => Promise<RegistrarSalvedadResult>;
  // Admin
  resolverSalvedad: (input: ResolverSalvedadInput) => Promise<{ success: boolean; nuevoEstado: EstadoResolucionSalvedad }>;
  anularSalvedad: (salvedadId: string, notas?: string) => Promise<{ success: boolean }>;
  // Consultas
  fetchSalvedadesPorPedido: (pedidoId: string) => Promise<SalvedadItemDBExtended[]>;
  fetchSalvedadesPendientes: () => Promise<SalvedadItemDBExtended[]>;
  fetchTodasSalvedades: () => Promise<SalvedadItemDBExtended[]>;
  fetchSalvedadesPorFecha: (desde: string, hasta?: string) => Promise<SalvedadItemDBExtended[]>;
  fetchSalvedadById: (id: string) => Promise<SalvedadItemDBExtended | null>;
  getEstadisticas: (desde?: string, hasta?: string) => Promise<EstadisticasSalvedades>;
  refetch: () => Promise<void>;
}

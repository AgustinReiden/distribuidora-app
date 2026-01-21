/**
 * Definiciones de tipos para la capa de servicios
 */

import type {
  Cliente,
  ClienteInput,
  Producto,
  ProductoInput,
  Pedido,
  PedidoInput,
  Usuario,
  UsuarioInput,
  Proveedor,
  Compra,
  Merma,
  Pago,
  Categoria,
  ServiceResponse,
  PaginatedResponse,
  QueryOptions
} from './index';

// =============================================================================
// BASE SERVICE
// =============================================================================

export interface BaseService<T, TInput = Partial<T>> {
  /**
   * Obtener todos los registros
   */
  getAll(options?: QueryOptions): Promise<ServiceResponse<T[]>>;

  /**
   * Obtener un registro por ID
   */
  getById(id: string): Promise<ServiceResponse<T>>;

  /**
   * Crear un nuevo registro
   */
  create(data: TInput): Promise<ServiceResponse<T>>;

  /**
   * Actualizar un registro existente
   */
  update(id: string, data: Partial<TInput>): Promise<ServiceResponse<T>>;

  /**
   * Eliminar un registro
   */
  delete(id: string): Promise<ServiceResponse<void>>;
}

// =============================================================================
// CLIENTE SERVICE
// =============================================================================

export interface ClienteService extends BaseService<Cliente, ClienteInput> {
  /**
   * Obtener clientes por zona
   */
  getByZona(zona: string): Promise<ServiceResponse<Cliente[]>>;

  /**
   * Obtener clientes con deuda
   */
  getConDeuda(): Promise<ServiceResponse<Cliente[]>>;

  /**
   * Actualizar saldo pendiente
   */
  actualizarSaldo(clienteId: string, monto: number): Promise<ServiceResponse<Cliente>>;

  /**
   * Obtener historial de pedidos del cliente
   */
  getHistorialPedidos(clienteId: string): Promise<ServiceResponse<Pedido[]>>;
}

// =============================================================================
// PRODUCTO SERVICE
// =============================================================================

export interface ProductoService extends BaseService<Producto, ProductoInput> {
  /**
   * Obtener productos por categoría
   */
  getByCategoria(categoriaId: string): Promise<ServiceResponse<Producto[]>>;

  /**
   * Obtener productos con stock bajo
   */
  getStockBajo(): Promise<ServiceResponse<Producto[]>>;

  /**
   * Actualizar stock
   */
  actualizarStock(
    productoId: string,
    cantidad: number,
    operacion: 'incrementar' | 'decrementar' | 'establecer'
  ): Promise<ServiceResponse<Producto>>;

  /**
   * Actualizar precios masivamente
   */
  actualizarPreciosMasivo(
    actualizaciones: Array<{
      id: string;
      precio_unitario?: number;
      precio_mayorista?: number;
    }>
  ): Promise<ServiceResponse<Producto[]>>;
}

// =============================================================================
// PEDIDO SERVICE
// =============================================================================

export interface PedidoService extends BaseService<Pedido, PedidoInput> {
  /**
   * Obtener pedidos por estado
   */
  getByEstado(estado: Pedido['estado']): Promise<ServiceResponse<Pedido[]>>;

  /**
   * Obtener pedidos de un transportista
   */
  getByTransportista(transportistaId: string): Promise<ServiceResponse<Pedido[]>>;

  /**
   * Obtener pedidos de un cliente
   */
  getByCliente(clienteId: string): Promise<ServiceResponse<Pedido[]>>;

  /**
   * Cambiar estado del pedido
   */
  cambiarEstado(
    pedidoId: string,
    nuevoEstado: Pedido['estado'],
    usuarioId?: string
  ): Promise<ServiceResponse<Pedido>>;

  /**
   * Asignar transportista
   */
  asignarTransportista(
    pedidoId: string,
    transportistaId: string
  ): Promise<ServiceResponse<Pedido>>;

  /**
   * Registrar pago
   */
  registrarPago(
    pedidoId: string,
    monto: number,
    formaPago: Pedido['forma_pago']
  ): Promise<ServiceResponse<Pedido>>;

  /**
   * Actualizar items del pedido
   */
  actualizarItems(
    pedidoId: string,
    items: PedidoInput['items'],
    usuarioId?: string
  ): Promise<ServiceResponse<Pedido>>;

  /**
   * Obtener historial de cambios
   */
  getHistorialCambios(pedidoId: string): Promise<ServiceResponse<unknown[]>>;

  /**
   * Obtener pedidos eliminados (soft delete)
   */
  getEliminados(): Promise<ServiceResponse<Pedido[]>>;

  /**
   * Restaurar pedido eliminado
   */
  restaurar(pedidoId: string): Promise<ServiceResponse<Pedido>>;
}

// =============================================================================
// USUARIO SERVICE
// =============================================================================

export interface UsuarioService extends BaseService<Usuario, UsuarioInput> {
  /**
   * Obtener usuarios por rol
   */
  getByRol(rol: Usuario['rol']): Promise<ServiceResponse<Usuario[]>>;

  /**
   * Obtener transportistas activos
   */
  getTransportistas(): Promise<ServiceResponse<Usuario[]>>;

  /**
   * Cambiar contraseña
   */
  cambiarPassword(
    usuarioId: string,
    passwordActual: string,
    passwordNueva: string
  ): Promise<ServiceResponse<void>>;
}

// =============================================================================
// COMPRA SERVICE
// =============================================================================

export interface CompraService extends BaseService<Compra> {
  /**
   * Obtener compras por proveedor
   */
  getByProveedor(proveedorId: string): Promise<ServiceResponse<Compra[]>>;

  /**
   * Obtener compras por rango de fechas
   */
  getByFechas(
    fechaDesde: string,
    fechaHasta: string
  ): Promise<ServiceResponse<Compra[]>>;

  /**
   * Anular compra (revierte stock)
   */
  anular(compraId: string): Promise<ServiceResponse<Compra>>;
}

// =============================================================================
// MERMA SERVICE
// =============================================================================

export interface MermaService extends BaseService<Merma> {
  /**
   * Obtener mermas por producto
   */
  getByProducto(productoId: string): Promise<ServiceResponse<Merma[]>>;

  /**
   * Obtener mermas por tipo
   */
  getByTipo(tipo: Merma['tipo']): Promise<ServiceResponse<Merma[]>>;

  /**
   * Obtener reporte de mermas
   */
  getReporte(
    fechaDesde: string,
    fechaHasta: string
  ): Promise<
    ServiceResponse<{
      total: number;
      porTipo: Record<Merma['tipo'], number>;
      porProducto: Array<{ producto: Producto; cantidad: number; valor: number }>;
    }>
  >;
}

// =============================================================================
// PAGO SERVICE
// =============================================================================

export interface PagoService extends BaseService<Pago> {
  /**
   * Obtener pagos de un cliente
   */
  getByCliente(clienteId: string): Promise<ServiceResponse<Pago[]>>;

  /**
   * Registrar pago y aplicar a pedidos pendientes
   */
  registrarYAplicar(
    clienteId: string,
    monto: number,
    formaPago: Pago['forma_pago'],
    pedidosIds?: string[]
  ): Promise<ServiceResponse<Pago>>;
}

// =============================================================================
// RUTA SERVICE
// =============================================================================

export interface RutaOptimizada {
  pedidos: Pedido[];
  distanciaTotal: number;
  tiempoEstimado: number;
  orden: string[];
}

export interface RutaService {
  /**
   * Optimizar ruta para un transportista
   */
  optimizar(
    transportistaId: string,
    pedidos: Pedido[]
  ): Promise<ServiceResponse<RutaOptimizada>>;

  /**
   * Aplicar orden de ruta
   */
  aplicarOrden(
    pedidosOrdenados: Array<{ id: string; orden_entrega: number }>
  ): Promise<ServiceResponse<void>>;

  /**
   * Exportar hoja de ruta a PDF
   */
  exportarPDF(
    transportista: Usuario,
    pedidos: Pedido[]
  ): Promise<ServiceResponse<Blob>>;
}

// =============================================================================
// CATEGORIA SERVICE
// =============================================================================

export interface CategoriaService extends BaseService<Categoria> {
  /**
   * Obtener categorías con conteo de productos
   */
  getConConteo(): Promise<
    ServiceResponse<Array<Categoria & { productosCount: number }>>
  >;
}

// =============================================================================
// PROVEEDOR SERVICE
// =============================================================================

export interface ProveedorService extends BaseService<Proveedor> {
  /**
   * Obtener historial de compras del proveedor
   */
  getHistorialCompras(proveedorId: string): Promise<ServiceResponse<Compra[]>>;
}

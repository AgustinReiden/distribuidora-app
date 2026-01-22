/**
 * Definiciones de tipos para la aplicación Distribuidora
 * Preparación para migración gradual a TypeScript
 */

// Re-exportar tipos de hooks
export * from './hooks'

// =============================================================================
// ENTIDADES BASE
// =============================================================================

export interface BaseEntity {
  id: string;
  created_at?: string;
  updated_at?: string;
}

// =============================================================================
// CLIENTE
// =============================================================================

export interface Cliente extends BaseEntity {
  nombre: string;
  direccion?: string;
  telefono?: string;
  email?: string;
  zona?: string;
  tipo?: 'minorista' | 'mayorista' | 'distribuidor';
  activo: boolean;
  saldo_pendiente?: number;
  notas?: string;
  latitud?: number;
  longitud?: number;
}

export interface ClienteInput {
  nombre: string;
  direccion?: string;
  telefono?: string;
  email?: string;
  zona?: string;
  tipo?: 'minorista' | 'mayorista' | 'distribuidor';
  notas?: string;
}

// =============================================================================
// PRODUCTO
// =============================================================================

export interface Producto extends BaseEntity {
  codigo?: string;
  nombre: string;
  descripcion?: string;
  precio_unitario: number;
  precio_mayorista?: number;
  stock: number;
  stock_minimo?: number;
  categoria_id?: string;
  activo: boolean;
  unidad?: string;
}

export interface ProductoInput {
  codigo?: string;
  nombre: string;
  descripcion?: string;
  precio_unitario: number;
  precio_mayorista?: number;
  stock?: number;
  stock_minimo?: number;
  categoria_id?: string;
  unidad?: string;
}

export interface Categoria extends BaseEntity {
  nombre: string;
  descripcion?: string;
  color?: string;
}

// =============================================================================
// PEDIDO
// =============================================================================

export type EstadoPedido =
  | 'pendiente'
  | 'en_preparacion'
  | 'preparado'
  | 'en_reparto'
  | 'entregado'
  | 'cancelado';

export type FormaPago = 'efectivo' | 'transferencia' | 'tarjeta' | 'cuenta_corriente';

export type EstadoPago = 'pendiente' | 'parcial' | 'pagado';

export interface PedidoItem {
  id?: string;
  producto_id: string;
  producto?: Producto;
  cantidad: number;
  precio_unitario: number;
  subtotal: number;
}

export interface Pedido extends BaseEntity {
  cliente_id: string;
  cliente?: Cliente;
  usuario_id?: string;
  transportista_id?: string;
  transportista?: Usuario;
  estado: EstadoPedido;
  estado_pago: EstadoPago;
  forma_pago: FormaPago;
  total: number;
  monto_pagado: number;
  notas?: string;
  fecha_entrega?: string;
  orden_entrega?: number;
  items?: PedidoItem[];
}

export interface PedidoInput {
  cliente_id: string;
  items: Array<{
    producto_id: string;
    cantidad: number;
    precio_unitario: number;
  }>;
  notas?: string;
  forma_pago?: FormaPago;
  estado_pago?: EstadoPago;
  monto_pagado?: number;
}

// =============================================================================
// USUARIO
// =============================================================================

export type RolUsuario = 'admin' | 'preventista' | 'transportista' | 'deposito';

export interface Usuario extends BaseEntity {
  email: string;
  nombre: string;
  rol: RolUsuario;
  activo: boolean;
  telefono?: string;
}

export interface UsuarioInput {
  email: string;
  nombre: string;
  rol: RolUsuario;
  telefono?: string;
  password?: string;
}

// =============================================================================
// PROVEEDOR
// =============================================================================

export interface Proveedor extends BaseEntity {
  nombre: string;
  contacto?: string;
  telefono?: string;
  email?: string;
  direccion?: string;
  notas?: string;
  activo: boolean;
}

// =============================================================================
// COMPRA
// =============================================================================

export interface CompraItem {
  id?: string;
  producto_id: string;
  producto?: Producto;
  cantidad: number;
  costo_unitario: number;
  subtotal: number;
}

export interface Compra extends BaseEntity {
  proveedor_id: string;
  proveedor?: Proveedor;
  usuario_id?: string;
  total: number;
  fecha: string;
  estado: 'activa' | 'anulada';
  notas?: string;
  items?: CompraItem[];
}

// =============================================================================
// MERMA
// =============================================================================

export type TipoMerma = 'vencimiento' | 'rotura' | 'robo' | 'otro';

export interface Merma extends BaseEntity {
  producto_id: string;
  producto?: Producto;
  usuario_id?: string;
  cantidad: number;
  tipo: TipoMerma;
  motivo?: string;
  fecha: string;
}

// =============================================================================
// PAGO
// =============================================================================

export interface Pago extends BaseEntity {
  cliente_id: string;
  cliente?: Cliente;
  usuario_id?: string;
  monto: number;
  forma_pago: FormaPago;
  fecha: string;
  notas?: string;
  pedidos_aplicados?: string[];
}

// =============================================================================
// SERVICIOS
// =============================================================================

export interface ServiceResponse<T> {
  data: T | null;
  error: Error | null;
}

export interface PaginatedResponse<T> {
  data: T[];
  count: number;
  page: number;
  pageSize: number;
  totalPages: number;
}

export interface ServiceOptions {
  signal?: AbortSignal;
}

export interface QueryOptions extends ServiceOptions {
  page?: number;
  pageSize?: number;
  orderBy?: string;
  orderDirection?: 'asc' | 'desc';
  filters?: Record<string, unknown>;
}

// =============================================================================
// HOOKS
// =============================================================================

export interface UseServiceResult<T> {
  data: T | null;
  loading: boolean;
  error: Error | null;
  refetch: () => Promise<void>;
}

export interface UseMutationResult<TData, TInput> {
  mutate: (input: TInput) => Promise<TData>;
  loading: boolean;
  error: Error | null;
  reset: () => void;
}

// =============================================================================
// ERROR HANDLING
// =============================================================================

export type ErrorCategory =
  | 'NETWORK'
  | 'AUTH'
  | 'VALIDATION'
  | 'DATABASE'
  | 'UNKNOWN';

export interface RecoveryInfo {
  message: string;
  canRetry: boolean;
  action?: string;
}

export interface CategorizedError {
  category: ErrorCategory;
  originalError: Error;
  recovery: RecoveryInfo;
}

// =============================================================================
// FILTROS Y BÚSQUEDA
// =============================================================================

export interface FiltrosPedidos {
  estado?: EstadoPedido | EstadoPedido[];
  estadoPago?: EstadoPago;
  transportistaId?: string;
  clienteId?: string;
  fechaDesde?: string;
  fechaHasta?: string;
  busqueda?: string;
}

export interface FiltrosProductos {
  categoriaId?: string;
  activo?: boolean;
  stockBajo?: boolean;
  busqueda?: string;
}

export interface FiltrosClientes {
  zona?: string;
  tipo?: Cliente['tipo'];
  activo?: boolean;
  conDeuda?: boolean;
  busqueda?: string;
}

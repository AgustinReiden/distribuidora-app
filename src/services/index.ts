/**
 * Capa de Servicios - Punto de entrada
 *
 * Esta capa abstrae las operaciones de Supabase y proporciona:
 * - Operaciones CRUD consistentes
 * - Lógica de negocio centralizada
 * - Manejo de errores unificado
 * - Fallbacks para operaciones RPC
 */

// Servicios de API (operaciones de base de datos)
export { BaseService } from './api/baseService'
export type { BaseServiceOptions, GetAllOptions, CreateOptions, FilterWithOperator } from './api/baseService'

export { clienteService } from './api/clienteService'
export type { ClienteWithPedidos, ResumenCuenta, ValidationResult as ClienteValidationResult } from './api/clienteService'

export { productoService } from './api/productoService'
export type { StockItem, PrecioUpdate, ActualizarPreciosResult, ProductoVendido, ValidationResult as ProductoValidationResult } from './api/productoService'

export { pedidoService } from './api/pedidoService'
export type {
  PedidoFiltros,
  PedidoData,
  PedidoItemInput,
  PedidoEstadisticas,
  PedidoHistorialEntry,
  OrdenEntrega
} from './api/pedidoService'

// Servicios de Negocio (lógica de dominio)
export { stockManager } from './business/stockManager'
export type {
  StockItem as StockManagerItem,
  StockFaltante,
  DisponibilidadResult,
  StockOperationResult,
  MermaInput,
  MermaFiltros,
  Merma,
  ResumenMovimientos
} from './business/stockManager'

// Re-exportar como objeto para conveniencia
import { clienteService } from './api/clienteService'
import { productoService } from './api/productoService'
import { pedidoService } from './api/pedidoService'
import { stockManager } from './business/stockManager'

export const services = {
  clientes: clienteService,
  productos: productoService,
  pedidos: pedidoService,
  stock: stockManager
}

export default services

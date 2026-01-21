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
export { clienteService } from './api/clienteService'
export { productoService } from './api/productoService'
export { pedidoService } from './api/pedidoService'

// Servicios de Negocio (lógica de dominio)
export { stockManager } from './business/stockManager'

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

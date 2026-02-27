/**
 * PedidoService - Servicio para operaciones de pedidos
 *
 * Este es el servicio más complejo ya que maneja:
 * - Creación de pedidos con items
 * - Gestión de stock
 * - Estados del pedido
 * - Historial de cambios
 */

import { BaseService } from './baseService'
import { logger } from '../../utils/logger'
import type { Pedido, PedidoItem, EstadoPedido } from '../../types'

export interface PedidoFiltros {
  estado?: string;
  clienteId?: string;
  preventistaId?: string;
  transportistaId?: string;
  fechaDesde?: string;
  fechaHasta?: string;
  metodoPago?: string;
  zona?: string;
}

export interface PedidoData {
  cliente_id: string;
  total: number;
  usuario_id: string;
  preventista_id?: string;
  transportista_id?: string | null;
  forma_pago?: string;
  estado_pago?: string;
  notas?: string;
}

export interface PedidoItemInput {
  producto_id: string;
  cantidad: number;
  precio_unitario: number;
}

export interface PedidoEstadisticas {
  total: number;
  porEstado: Record<string, number>;
  totalVentas: number;
  promedioTicket: number;
  pendientes: number;
  entregados: number;
}

export interface PedidoHistorialEntry {
  id: string;
  pedido_id: string;
  accion: string;
  descripcion: string;
  fecha: string;
}

export interface OrdenEntrega {
  pedido_id: string;
  orden_entrega: number;
}

class PedidoService extends BaseService<Pedido> {
  constructor() {
    super('pedidos', {
      orderBy: 'fecha_creacion',
      ascending: false,
      selectQuery: `
        *,
        cliente:clientes(id, nombre_fantasia, direccion, telefono, zona, lat, lng),
        preventista:perfiles!pedidos_preventista_id_fkey(id, nombre),
        transportista:perfiles!pedidos_transportista_id_fkey(id, nombre),
        items:pedido_items(
          id,
          producto_id,
          cantidad,
          precio_unitario,
          subtotal,
          producto:productos(id, nombre, codigo)
        )
      `
    })
  }

  /**
   * Obtiene pedidos con filtros avanzados
   */
  async getPedidosFiltrados(filtros: PedidoFiltros = {}): Promise<Pedido[]> {
    const {
      estado,
      clienteId,
      preventistaId,
      transportistaId,
      fechaDesde,
      fechaHasta,
      metodoPago,
      zona
    } = filtros

    return this.query(async (query) => {
      let q = query.select(this.selectQuery)

      if (estado && estado !== 'todos') {
        q = q.eq('estado', estado)
      }

      if (clienteId) {
        q = q.eq('cliente_id', clienteId)
      }

      if (preventistaId) {
        q = q.eq('preventista_id', preventistaId)
      }

      if (transportistaId) {
        q = q.eq('transportista_id', transportistaId)
      }

      if (fechaDesde) {
        q = q.gte('fecha_creacion', fechaDesde)
      }

      if (fechaHasta) {
        q = q.lte('fecha_creacion', fechaHasta)
      }

      if (metodoPago) {
        q = q.eq('metodo_pago', metodoPago)
      }

      // Filtrar por zona requiere join con clientes
      if (zona) {
        q = q.eq('cliente.zona', zona)
      }

      return q.order('fecha_creacion', { ascending: false })
    }) as unknown as Promise<Pedido[]>
  }

  /**
   * Crea un pedido completo con items
   *
   * Usa la RPC 'crear_pedido_completo' que es una transacción atómica.
   * Si falla, es por una razón válida (stock insuficiente, constraint, etc.)
   * y NO se debe intentar crear manualmente.
   */
  async crearPedidoCompleto(pedidoData: PedidoData, items: PedidoItemInput[], _descontarStock = true): Promise<Pedido> {
    return this.rpc<Pedido>('crear_pedido_completo', {
      p_cliente_id: pedidoData.cliente_id,
      p_total: pedidoData.total,
      p_usuario_id: pedidoData.usuario_id,
      p_items: JSON.stringify(items),
      p_notas: pedidoData.notas || '',
      p_forma_pago: pedidoData.forma_pago || 'efectivo',
      p_estado_pago: pedidoData.estado_pago || 'pendiente'
    })
  }

  /**
   * Actualiza items de un pedido existente
   *
   * Usa la RPC 'actualizar_pedido_items' que es una transacción atómica.
   * Restaura el stock de items anteriores y descuenta el de los nuevos
   * en una sola transacción.
   */
  async actualizarItems(pedidoId: string, nuevosItems: PedidoItemInput[]): Promise<Pedido | null> {
    return this.rpc<Pedido | null>('actualizar_pedido_items', {
      p_pedido_id: pedidoId,
      p_items: JSON.stringify(nuevosItems)
    })
  }

  /**
   * Cambia el estado de un pedido
   */
  async cambiarEstado(pedidoId: string, nuevoEstado: EstadoPedido, notas = ''): Promise<Pedido | null> {
    const estadosValidos: EstadoPedido[] = ['pendiente', 'en_preparacion', 'en_reparto', 'entregado', 'cancelado']

    if (!estadosValidos.includes(nuevoEstado)) {
      throw new Error(`Estado inválido: ${nuevoEstado}`)
    }

    const updates: Partial<Pedido> = { estado: nuevoEstado }

    // Agregar timestamp según estado
    if (nuevoEstado === 'entregado') {
      updates.fecha_entrega = new Date().toISOString()
    }

    const pedido = await this.update(pedidoId, updates)

    // Registrar en historial
    await this.registrarHistorial(pedidoId, nuevoEstado, notas)

    return pedido
  }

  /**
   * Asigna transportista a un pedido
   */
  async asignarTransportista(pedidoId: string, transportistaId: string): Promise<Pedido | null> {
    const pedido = await this.update(pedidoId, {
      transportista_id: transportistaId,
      estado: 'en_reparto' as EstadoPedido
    })

    await this.registrarHistorial(
      pedidoId,
      'transportista_asignado',
      `Transportista asignado: ${transportistaId}`
    )

    return pedido
  }

  /**
   * Elimina un pedido con rollback de stock
   *
   * Usa la RPC 'eliminar_pedido_completo' que es una transacción atómica.
   * Guarda el pedido en auditoría, restaura stock y elimina items
   * en una sola transacción.
   */
  async eliminarPedido(pedidoId: string, restaurarStock = true, motivo = ''): Promise<boolean> {
    return this.rpc<boolean>('eliminar_pedido_completo', {
      p_pedido_id: pedidoId,
      p_restaurar_stock: restaurarStock,
      p_motivo: motivo
    })
  }

  /**
   * Actualiza orden de entrega para ruta optimizada
   *
   * Nota: Este método usa un fallback seguro porque cada actualización
   * de orden es independiente y no afecta la integridad de datos.
   */
  async actualizarOrdenEntrega(ordenes: OrdenEntrega[]): Promise<boolean> {
    try {
      // Intentar RPC batch primero (más eficiente)
      return await this.rpc<boolean>('actualizar_orden_entrega_batch', {
        ordenes: JSON.stringify(ordenes)
      })
    } catch {
      // Fallback seguro: actualizar uno por uno
      // Esto es aceptable porque cada orden_entrega es independiente
      for (const orden of ordenes) {
        await this.update(orden.pedido_id, {
          orden_entrega: orden.orden_entrega
        })
      }
      return true
    }
  }

  /**
   * Registra evento en historial del pedido
   */
  async registrarHistorial(pedidoId: string, accion: string, descripcion = ''): Promise<void> {
    try {
      await this.db.from('pedido_historial').insert({
        pedido_id: pedidoId,
        accion: accion,
        descripcion: descripcion,
        fecha: new Date().toISOString()
      })
    } catch (error) {
      // No fallar si el historial falla
      logger.warn('Error registrando historial:', error)
    }
  }

  /**
   * Obtiene historial de un pedido
   */
  async getHistorial(pedidoId: string): Promise<PedidoHistorialEntry[]> {
    const { data, error } = await this.db
      .from('pedido_historial')
      .select('*')
      .eq('pedido_id', pedidoId)
      .order('fecha', { ascending: false })

    if (error) {
      this.handleError('obtener historial', error)
      return []
    }

    return (data || []) as PedidoHistorialEntry[]
  }

  /**
   * Obtiene pedidos eliminados para auditoría
   */
  async getPedidosEliminados(): Promise<unknown[]> {
    const { data, error } = await this.db
      .from('pedidos_eliminados')
      .select('*')
      .order('fecha_eliminacion', { ascending: false })

    if (error) {
      this.handleError('obtener pedidos eliminados', error)
      return []
    }

    return data || []
  }

  /**
   * Obtiene estadísticas de pedidos
   */
  async getEstadisticas(desde: Date | null = null, hasta: Date | null = null): Promise<PedidoEstadisticas> {
    let query = this.db.from(this.table).select('*')

    if (desde) {
      query = query.gte('fecha_creacion', desde.toISOString())
    }
    if (hasta) {
      query = query.lte('fecha_creacion', hasta.toISOString())
    }

    const { data, error } = await query

    if (error) {
      this.handleError('obtener estadísticas', error)
      return {
        total: 0,
        porEstado: {},
        totalVentas: 0,
        promedioTicket: 0,
        pendientes: 0,
        entregados: 0
      }
    }

    const pedidos = (data || []) as Pedido[]

    // Calcular estadísticas
    const porEstado = pedidos.reduce((acc: Record<string, number>, p) => {
      acc[p.estado] = (acc[p.estado] || 0) + 1
      return acc
    }, {})

    const pedidosEntregados = pedidos.filter(p => p.estado === 'entregado')
    const totalVentas = pedidosEntregados.reduce((sum, p) => sum + (p.total || 0), 0)

    const promedioTicket = pedidosEntregados.length > 0
      ? totalVentas / pedidosEntregados.length
      : 0

    return {
      total: pedidos.length,
      porEstado,
      totalVentas,
      promedioTicket,
      pendientes: porEstado.pendiente || 0,
      entregados: porEstado.entregado || 0
    }
  }
}

// Singleton
export const pedidoService = new PedidoService()
export default pedidoService

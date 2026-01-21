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
import { productoService } from './productoService'

class PedidoService extends BaseService {
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
   * @param {Object} filtros
   * @returns {Promise<Array>}
   */
  async getPedidosFiltrados(filtros = {}) {
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
    })
  }

  /**
   * Crea un pedido completo con items
   * @param {Object} pedidoData - Datos del pedido
   * @param {Array} items - Items del pedido
   * @param {boolean} descontarStock - Si debe descontar stock
   * @returns {Promise<Object>}
   */
  async crearPedidoCompleto(pedidoData, items, descontarStock = true) {
    // Intentar con RPC primero
    return this.rpc(
      'crear_pedido_completo',
      {
        p_cliente_id: pedidoData.cliente_id,
        p_preventista_id: pedidoData.preventista_id,
        p_items: JSON.stringify(items),
        p_notas: pedidoData.notas || '',
        p_metodo_pago: pedidoData.metodo_pago || 'efectivo',
        p_descuento: pedidoData.descuento || 0
      },
      async () => {
        // Fallback: crear manualmente
        return this.crearPedidoManual(pedidoData, items, descontarStock)
      }
    )
  }

  /**
   * Crea pedido manualmente (fallback)
   */
  async crearPedidoManual(pedidoData, items, descontarStock) {
    // Calcular total
    const total = items.reduce((sum, item) => {
      return sum + (item.cantidad * item.precio_unitario)
    }, 0)

    const totalConDescuento = total - (pedidoData.descuento || 0)

    // Crear pedido
    const pedido = await this.create({
      cliente_id: pedidoData.cliente_id,
      preventista_id: pedidoData.preventista_id,
      transportista_id: pedidoData.transportista_id || null,
      estado: 'pendiente',
      metodo_pago: pedidoData.metodo_pago || 'efectivo',
      notas: pedidoData.notas || '',
      descuento: pedidoData.descuento || 0,
      total: totalConDescuento,
      fecha_creacion: new Date().toISOString()
    })

    // Crear items
    const itemsConPedidoId = items.map(item => ({
      pedido_id: pedido.id,
      producto_id: item.producto_id,
      cantidad: item.cantidad,
      precio_unitario: item.precio_unitario,
      subtotal: item.cantidad * item.precio_unitario
    }))

    await this.db.from('pedido_items').insert(itemsConPedidoId)

    // Descontar stock si es necesario
    if (descontarStock) {
      await productoService.descontarStock(
        items.map(i => ({
          producto_id: i.producto_id,
          cantidad: i.cantidad
        }))
      )
    }

    // Registrar en historial
    await this.registrarHistorial(pedido.id, 'creado', 'Pedido creado')

    return pedido
  }

  /**
   * Actualiza items de un pedido existente
   * @param {string} pedidoId
   * @param {Array} nuevosItems
   * @returns {Promise<Object>}
   */
  async actualizarItems(pedidoId, nuevosItems) {
    return this.rpc(
      'actualizar_pedido_items',
      {
        p_pedido_id: pedidoId,
        p_items: JSON.stringify(nuevosItems)
      },
      async () => {
        // Fallback manual
        // 1. Obtener items actuales para restaurar stock
        const { data: itemsActuales } = await this.db
          .from('pedido_items')
          .select('producto_id, cantidad')
          .eq('pedido_id', pedidoId)

        // 2. Restaurar stock de items actuales
        if (itemsActuales?.length) {
          await productoService.restaurarStock(itemsActuales)
        }

        // 3. Eliminar items actuales
        await this.db.from('pedido_items').delete().eq('pedido_id', pedidoId)

        // 4. Insertar nuevos items
        const itemsParaInsertar = nuevosItems.map(item => ({
          pedido_id: pedidoId,
          producto_id: item.producto_id,
          cantidad: item.cantidad,
          precio_unitario: item.precio_unitario,
          subtotal: item.cantidad * item.precio_unitario
        }))

        await this.db.from('pedido_items').insert(itemsParaInsertar)

        // 5. Descontar stock de nuevos items
        await productoService.descontarStock(
          nuevosItems.map(i => ({
            producto_id: i.producto_id,
            cantidad: i.cantidad
          }))
        )

        // 6. Actualizar total del pedido
        const nuevoTotal = nuevosItems.reduce(
          (sum, item) => sum + (item.cantidad * item.precio_unitario),
          0
        )

        return this.update(pedidoId, { total: nuevoTotal })
      }
    )
  }

  /**
   * Cambia el estado de un pedido
   * @param {string} pedidoId
   * @param {string} nuevoEstado
   * @param {string} notas
   * @returns {Promise<Object>}
   */
  async cambiarEstado(pedidoId, nuevoEstado, notas = '') {
    const estadosValidos = ['pendiente', 'en_preparacion', 'en_camino', 'entregado', 'cancelado']

    if (!estadosValidos.includes(nuevoEstado)) {
      throw new Error(`Estado inválido: ${nuevoEstado}`)
    }

    const updates = { estado: nuevoEstado }

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
   * @param {string} pedidoId
   * @param {string} transportistaId
   * @returns {Promise<Object>}
   */
  async asignarTransportista(pedidoId, transportistaId) {
    const pedido = await this.update(pedidoId, {
      transportista_id: transportistaId,
      estado: 'en_camino'
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
   * @param {string} pedidoId
   * @param {boolean} restaurarStock
   * @param {string} motivo
   * @returns {Promise<boolean>}
   */
  async eliminarPedido(pedidoId, restaurarStock = true, motivo = '') {
    return this.rpc(
      'eliminar_pedido_completo',
      {
        p_pedido_id: pedidoId,
        p_restaurar_stock: restaurarStock,
        p_motivo: motivo
      },
      async () => {
        // Fallback manual
        // 1. Obtener pedido con items
        const pedido = await this.getById(pedidoId)
        if (!pedido) {
          throw new Error('Pedido no encontrado')
        }

        // 2. Obtener items para restaurar stock
        const { data: items } = await this.db
          .from('pedido_items')
          .select('producto_id, cantidad')
          .eq('pedido_id', pedidoId)

        // 3. Guardar en pedidos_eliminados para auditoría
        await this.db.from('pedidos_eliminados').insert({
          pedido_id: pedidoId,
          datos_pedido: pedido,
          motivo: motivo,
          eliminado_por: null, // Se podría pasar el userId
          fecha_eliminacion: new Date().toISOString()
        })

        // 4. Eliminar items
        await this.db.from('pedido_items').delete().eq('pedido_id', pedidoId)

        // 5. Eliminar pedido
        await this.delete(pedidoId)

        // 6. Restaurar stock si es necesario
        if (restaurarStock && items?.length) {
          await productoService.restaurarStock(items)
        }

        return true
      }
    )
  }

  /**
   * Actualiza orden de entrega para ruta optimizada
   * @param {Array<{pedido_id: string, orden_entrega: number}>} ordenes
   * @returns {Promise<boolean>}
   */
  async actualizarOrdenEntrega(ordenes) {
    return this.rpc(
      'actualizar_orden_entrega_batch',
      { ordenes: JSON.stringify(ordenes) },
      async () => {
        // Fallback: actualizar uno por uno
        for (const orden of ordenes) {
          await this.update(orden.pedido_id, {
            orden_entrega: orden.orden_entrega
          })
        }
        return true
      }
    )
  }

  /**
   * Registra evento en historial del pedido
   * @param {string} pedidoId
   * @param {string} accion
   * @param {string} descripcion
   */
  async registrarHistorial(pedidoId, accion, descripcion = '') {
    try {
      await this.db.from('pedido_historial').insert({
        pedido_id: pedidoId,
        accion: accion,
        descripcion: descripcion,
        fecha: new Date().toISOString()
      })
    } catch (error) {
      // No fallar si el historial falla
      console.warn('Error registrando historial:', error)
    }
  }

  /**
   * Obtiene historial de un pedido
   * @param {string} pedidoId
   * @returns {Promise<Array>}
   */
  async getHistorial(pedidoId) {
    const { data, error } = await this.db
      .from('pedido_historial')
      .select('*')
      .eq('pedido_id', pedidoId)
      .order('fecha', { ascending: false })

    if (error) {
      this.handleError('obtener historial', error)
      return []
    }

    return data || []
  }

  /**
   * Obtiene pedidos eliminados para auditoría
   * @returns {Promise<Array>}
   */
  async getPedidosEliminados() {
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
   * @param {Date} desde
   * @param {Date} hasta
   * @returns {Promise<Object>}
   */
  async getEstadisticas(desde = null, hasta = null) {
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
      return {}
    }

    const pedidos = data || []

    // Calcular estadísticas
    const porEstado = pedidos.reduce((acc, p) => {
      acc[p.estado] = (acc[p.estado] || 0) + 1
      return acc
    }, {})

    const totalVentas = pedidos
      .filter(p => p.estado === 'entregado')
      .reduce((sum, p) => sum + (p.total || 0), 0)

    const promedioTicket = pedidos.length > 0
      ? totalVentas / pedidos.filter(p => p.estado === 'entregado').length
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

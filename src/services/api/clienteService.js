/**
 * ClienteService - Servicio para operaciones de clientes
 */

import { BaseService } from './baseService'

class ClienteService extends BaseService {
  constructor() {
    super('clientes', {
      orderBy: 'nombre_fantasia',
      ascending: true
    })
  }

  /**
   * Obtiene clientes con sus pedidos pendientes
   * @returns {Promise<Array>}
   */
  async getWithPendingOrders() {
    return this.getAll({
      selectQuery: `
        *,
        pedidos:pedidos(id, estado, total, fecha_creacion)
      `
    })
  }

  /**
   * Obtiene clientes por zona
   * @param {string} zona
   * @returns {Promise<Array>}
   */
  async getByZona(zona) {
    return this.getAll({
      filters: { zona }
    })
  }

  /**
   * Obtiene clientes activos (con pedidos en los últimos N días)
   * @param {number} dias
   * @returns {Promise<Array>}
   */
  async getActivos(dias = 30) {
    const fechaLimite = new Date()
    fechaLimite.setDate(fechaLimite.getDate() - dias)

    return this.query(async (query) => {
      return query
        .select(`
          *,
          pedidos:pedidos(id, fecha_creacion)
        `)
        .gte('pedidos.fecha_creacion', fechaLimite.toISOString())
        .order('nombre_fantasia')
    })
  }

  /**
   * Busca clientes por nombre o razón social
   * @param {string} termino
   * @returns {Promise<Array>}
   */
  async buscar(termino) {
    return this.query(async (query) => {
      return query
        .select('*')
        .or(`nombre_fantasia.ilike.%${termino}%,razon_social.ilike.%${termino}%`)
        .order('nombre_fantasia')
    })
  }

  /**
   * Obtiene resumen de cuenta del cliente
   * @param {string} clienteId
   * @returns {Promise<Object>}
   */
  async getResumenCuenta(clienteId) {
    return this.rpc(
      'obtener_resumen_cuenta_cliente',
      { p_cliente_id: clienteId },
      async () => {
        // Fallback: calcular manualmente
        const pedidos = await this.db
          .from('pedidos')
          .select('total, estado, metodo_pago')
          .eq('cliente_id', clienteId)
          .in('estado', ['pendiente', 'en_preparacion', 'en_camino', 'entregado'])

        const pagos = await this.db
          .from('pagos')
          .select('monto')
          .eq('cliente_id', clienteId)

        const totalPedidos = pedidos.data?.reduce((sum, p) => sum + (p.total || 0), 0) || 0
        const totalPagos = pagos.data?.reduce((sum, p) => sum + (p.monto || 0), 0) || 0

        return {
          total_pedidos: totalPedidos,
          total_pagos: totalPagos,
          saldo: totalPedidos - totalPagos
        }
      }
    )
  }

  /**
   * Valida datos del cliente antes de guardar
   * @param {Object} data
   * @returns {{ valid: boolean, errors: string[] }}
   */
  validate(data) {
    const errors = []

    if (!data.nombre_fantasia?.trim()) {
      errors.push('El nombre de fantasía es requerido')
    }

    if (!data.direccion?.trim()) {
      errors.push('La dirección es requerida')
    }

    if (data.telefono && !/^[\d\s\-+()]+$/.test(data.telefono)) {
      errors.push('El teléfono tiene un formato inválido')
    }

    if (data.email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(data.email)) {
      errors.push('El email tiene un formato inválido')
    }

    return {
      valid: errors.length === 0,
      errors
    }
  }
}

// Singleton
export const clienteService = new ClienteService()
export default clienteService

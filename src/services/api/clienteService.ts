/**
 * ClienteService - Servicio para operaciones de clientes
 */

import { BaseService } from './baseService'
import { escapePostgrestFilter } from '../../utils/sanitize'
import type { Cliente } from '../../types'

export interface ClienteWithPedidos extends Cliente {
  pedidos?: Array<{
    id: string;
    estado: string;
    total: number;
    fecha_creacion: string;
  }>;
}

export interface ResumenCuenta {
  total_pedidos: number;
  total_pagos: number;
  saldo: number;
}

export interface ValidationResult {
  valid: boolean;
  errors: string[];
}

class ClienteService extends BaseService<Cliente> {
  constructor() {
    super('clientes', {
      orderBy: 'nombre_fantasia',
      ascending: true
    })
  }

  /**
   * Obtiene clientes con sus pedidos pendientes
   */
  async getWithPendingOrders(): Promise<ClienteWithPedidos[]> {
    return this.getAll({
      selectQuery: `
        *,
        pedidos:pedidos(id, estado, total, fecha_creacion)
      `
    }) as Promise<ClienteWithPedidos[]>
  }

  /**
   * Obtiene clientes por zona
   */
  async getByZona(zona: string): Promise<Cliente[]> {
    return this.getAll({
      filters: { zona }
    })
  }

  /**
   * Obtiene clientes activos (con pedidos en los últimos N días)
   */
  async getActivos(dias = 30): Promise<ClienteWithPedidos[]> {
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
    }) as Promise<ClienteWithPedidos[]>
  }

  /**
   * Busca clientes por nombre o razón social.
   * Sanitiza el término de búsqueda para prevenir inyección PostgREST.
   */
  async buscar(termino: string): Promise<Cliente[]> {
    const safe = escapePostgrestFilter(termino)
    if (!safe) return []

    return this.query(async (query) => {
      return query
        .select('*')
        .or(`nombre_fantasia.ilike.%${safe}%,razon_social.ilike.%${safe}%`)
        .order('nombre_fantasia')
    }) as Promise<Cliente[]>
  }

  /**
   * Obtiene resumen de cuenta del cliente
   */
  async getResumenCuenta(clienteId: string): Promise<ResumenCuenta> {
    return this.rpc<ResumenCuenta>(
      'obtener_resumen_cuenta_cliente',
      { p_cliente_id: clienteId }
    )
  }

  /**
   * Valida datos del cliente antes de guardar
   */
  validate(data: Partial<Cliente> & { nombre_fantasia?: string; direccion?: string }): ValidationResult {
    const errors: string[] = []

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

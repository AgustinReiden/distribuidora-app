/**
 * BaseService - Servicio base con operaciones CRUD genéricas
 *
 * Elimina la duplicación de código presente en los hooks de Supabase
 * proporcionando una interfaz consistente para operaciones de base de datos.
 */

import { supabase, notifyError } from '../../hooks/supabase/base'

export class BaseService {
  /**
   * @param {string} tableName - Nombre de la tabla en Supabase
   * @param {Object} options - Opciones de configuración
   * @param {string} options.orderBy - Campo para ordenar por defecto
   * @param {boolean} options.ascending - Orden ascendente (default: true)
   * @param {string} options.selectQuery - Query SELECT personalizada
   */
  constructor(tableName, options = {}) {
    this.table = tableName
    this.db = supabase
    this.orderBy = options.orderBy || 'id'
    this.ascending = options.ascending !== false
    this.selectQuery = options.selectQuery || '*'
  }

  /**
   * Obtiene todos los registros de la tabla
   * @param {Object} options - Opciones de query
   * @returns {Promise<Array>}
   */
  async getAll(options = {}) {
    const {
      orderBy = this.orderBy,
      ascending = this.ascending,
      selectQuery = this.selectQuery,
      filters = {}
    } = options

    try {
      let query = this.db.from(this.table).select(selectQuery)

      // Aplicar filtros
      Object.entries(filters).forEach(([key, value]) => {
        if (value !== undefined && value !== null && value !== '') {
          if (typeof value === 'object' && value.operator) {
            // Filtro con operador personalizado: { operator: 'gte', value: 10 }
            query = query[value.operator](key, value.value)
          } else {
            query = query.eq(key, value)
          }
        }
      })

      // Ordenar
      query = query.order(orderBy, { ascending })

      const { data, error } = await query

      if (error) throw error
      return data || []
    } catch (error) {
      this.handleError('obtener registros', error)
      return []
    }
  }

  /**
   * Obtiene un registro por ID
   * @param {string|number} id
   * @returns {Promise<Object|null>}
   */
  async getById(id) {
    try {
      const { data, error } = await this.db
        .from(this.table)
        .select(this.selectQuery)
        .eq('id', id)
        .single()

      if (error) throw error
      return data
    } catch (error) {
      this.handleError('obtener registro', error)
      return null
    }
  }

  /**
   * Crea un nuevo registro
   * @param {Object} data - Datos del registro
   * @param {Object} options - Opciones
   * @returns {Promise<Object|null>}
   */
  async create(data, options = {}) {
    const { returnData = true } = options

    try {
      let query = this.db.from(this.table).insert([data])

      if (returnData) {
        query = query.select().single()
      }

      const { data: result, error } = await query

      if (error) throw error
      return returnData ? result : true
    } catch (error) {
      this.handleError('crear registro', error)
      throw error // Re-throw para que el llamador pueda manejar el error
    }
  }

  /**
   * Crea múltiples registros
   * @param {Array<Object>} items - Array de datos
   * @returns {Promise<Array>}
   */
  async createMany(items) {
    try {
      const { data, error } = await this.db
        .from(this.table)
        .insert(items)
        .select()

      if (error) throw error
      return data || []
    } catch (error) {
      this.handleError('crear registros', error)
      throw error
    }
  }

  /**
   * Actualiza un registro por ID
   * @param {string|number} id
   * @param {Object} data - Datos a actualizar
   * @returns {Promise<Object|null>}
   */
  async update(id, data) {
    try {
      const { data: result, error } = await this.db
        .from(this.table)
        .update(data)
        .eq('id', id)
        .select()
        .single()

      if (error) throw error
      return result
    } catch (error) {
      this.handleError('actualizar registro', error)
      throw error
    }
  }

  /**
   * Actualiza múltiples registros con un filtro
   * @param {Object} filters - Filtros para seleccionar registros
   * @param {Object} data - Datos a actualizar
   * @returns {Promise<Array>}
   */
  async updateWhere(filters, data) {
    try {
      let query = this.db.from(this.table).update(data)

      Object.entries(filters).forEach(([key, value]) => {
        query = query.eq(key, value)
      })

      const { data: result, error } = await query.select()

      if (error) throw error
      return result || []
    } catch (error) {
      this.handleError('actualizar registros', error)
      throw error
    }
  }

  /**
   * Elimina un registro por ID
   * @param {string|number} id
   * @returns {Promise<boolean>}
   */
  async delete(id) {
    try {
      const { error } = await this.db
        .from(this.table)
        .delete()
        .eq('id', id)

      if (error) throw error
      return true
    } catch (error) {
      this.handleError('eliminar registro', error)
      throw error
    }
  }

  /**
   * Elimina múltiples registros con un filtro
   * @param {Object} filters
   * @returns {Promise<boolean>}
   */
  async deleteWhere(filters) {
    try {
      let query = this.db.from(this.table).delete()

      Object.entries(filters).forEach(([key, value]) => {
        query = query.eq(key, value)
      })

      const { error } = await query

      if (error) throw error
      return true
    } catch (error) {
      this.handleError('eliminar registros', error)
      throw error
    }
  }

  /**
   * Ejecuta una función RPC de Supabase con fallback
   * @param {string} functionName - Nombre de la función RPC
   * @param {Object} params - Parámetros
   * @param {Function} fallback - Función fallback si RPC falla
   * @returns {Promise<any>}
   */
  async rpc(functionName, params = {}, fallback = null) {
    try {
      const { data, error } = await this.db.rpc(functionName, params)

      if (error) {
        if (fallback) {
          console.warn(`RPC ${functionName} falló, usando fallback:`, error.message)
          return await fallback()
        }
        throw error
      }

      return data
    } catch (error) {
      if (fallback) {
        console.warn(`RPC ${functionName} error, usando fallback:`, error.message)
        return await fallback()
      }
      this.handleError(`ejecutar ${functionName}`, error)
      throw error
    }
  }

  /**
   * Cuenta registros con filtros opcionales
   * @param {Object} filters
   * @returns {Promise<number>}
   */
  async count(filters = {}) {
    try {
      let query = this.db
        .from(this.table)
        .select('*', { count: 'exact', head: true })

      Object.entries(filters).forEach(([key, value]) => {
        if (value !== undefined && value !== null) {
          query = query.eq(key, value)
        }
      })

      const { count, error } = await query

      if (error) throw error
      return count || 0
    } catch (error) {
      this.handleError('contar registros', error)
      return 0
    }
  }

  /**
   * Verifica si existe un registro
   * @param {Object} filters
   * @returns {Promise<boolean>}
   */
  async exists(filters) {
    const count = await this.count(filters)
    return count > 0
  }

  /**
   * Query personalizada
   * @param {Function} queryBuilder - Función que recibe query base
   * @returns {Promise<any>}
   */
  async query(queryBuilder) {
    try {
      const baseQuery = this.db.from(this.table)
      const { data, error } = await queryBuilder(baseQuery)

      if (error) throw error
      return data
    } catch (error) {
      this.handleError('ejecutar query', error)
      throw error
    }
  }

  /**
   * Maneja errores de forma consistente
   * @param {string} operation
   * @param {Error} error
   */
  handleError(operation, error) {
    const message = `Error al ${operation} en ${this.table}: ${error.message}`
    console.error(message, error)
    notifyError(message)
  }
}

export default BaseService

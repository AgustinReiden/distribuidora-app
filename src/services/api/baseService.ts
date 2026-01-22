/**
 * BaseService - Servicio base con operaciones CRUD genéricas
 *
 * Elimina la duplicación de código presente en los hooks de Supabase
 * proporcionando una interfaz consistente para operaciones de base de datos.
 */

import { supabase, notifyError } from '../../hooks/supabase/base'
import type { SupabaseClient } from '@supabase/supabase-js'

// Type for filter builder - using generic type to avoid importing non-exported types
type FilterBuilder = ReturnType<ReturnType<SupabaseClient['from']>['select']>;

export interface FilterWithOperator {
  operator: string;
  value: unknown;
}

export interface BaseServiceOptions {
  orderBy?: string;
  ascending?: boolean;
  selectQuery?: string;
}

export interface GetAllOptions {
  orderBy?: string;
  ascending?: boolean;
  selectQuery?: string;
  filters?: Record<string, unknown | FilterWithOperator>;
}

export interface CreateOptions {
  returnData?: boolean;
}

export class BaseService<T = Record<string, unknown>> {
  protected table: string;
  protected db: SupabaseClient;
  protected orderBy: string;
  protected ascending: boolean;
  protected selectQuery: string;

  constructor(tableName: string, options: BaseServiceOptions = {}) {
    this.table = tableName
    this.db = supabase
    this.orderBy = options.orderBy || 'id'
    this.ascending = options.ascending !== false
    this.selectQuery = options.selectQuery || '*'
  }

  /**
   * Obtiene todos los registros de la tabla
   */
  async getAll(options: GetAllOptions = {}): Promise<T[]> {
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
          if (typeof value === 'object' && value !== null && 'operator' in value) {
            // Filtro con operador personalizado: { operator: 'gte', value: 10 }
            const filterValue = value as FilterWithOperator
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            const filterMethod = (query as any)[filterValue.operator]
            if (typeof filterMethod === 'function') {
              query = filterMethod.call(query, key, filterValue.value)
            }
          } else {
            query = query.eq(key, value)
          }
        }
      })

      // Ordenar
      query = query.order(orderBy, { ascending })

      const { data, error } = await query

      if (error) throw error
      return (data || []) as T[]
    } catch (error) {
      this.handleError('obtener registros', error as Error)
      return []
    }
  }

  /**
   * Obtiene un registro por ID
   */
  async getById(id: string | number): Promise<T | null> {
    try {
      const { data, error } = await this.db
        .from(this.table)
        .select(this.selectQuery)
        .eq('id', id)
        .single()

      if (error) throw error
      return data as T
    } catch (error) {
      this.handleError('obtener registro', error as Error)
      return null
    }
  }

  /**
   * Crea un nuevo registro
   */
  async create(data: Partial<T>, options: CreateOptions = {}): Promise<T | boolean> {
    const { returnData = true } = options

    try {
      if (returnData) {
        const { data: result, error } = await this.db
          .from(this.table)
          .insert([data])
          .select()
          .single()

        if (error) throw error
        return result as T
      } else {
        const { error } = await this.db.from(this.table).insert([data])
        if (error) throw error
        return true
      }
    } catch (error) {
      this.handleError('crear registro', error as Error)
      throw error // Re-throw para que el llamador pueda manejar el error
    }
  }

  /**
   * Crea múltiples registros
   */
  async createMany(items: Partial<T>[]): Promise<T[]> {
    try {
      const { data, error } = await this.db
        .from(this.table)
        .insert(items)
        .select()

      if (error) throw error
      return (data || []) as T[]
    } catch (error) {
      this.handleError('crear registros', error as Error)
      throw error
    }
  }

  /**
   * Actualiza un registro por ID
   */
  async update(id: string | number, data: Partial<T>): Promise<T | null> {
    try {
      const { data: result, error } = await this.db
        .from(this.table)
        .update(data)
        .eq('id', id)
        .select()
        .single()

      if (error) throw error
      return result as T
    } catch (error) {
      this.handleError('actualizar registro', error as Error)
      throw error
    }
  }

  /**
   * Actualiza múltiples registros con un filtro
   */
  async updateWhere(filters: Record<string, unknown>, data: Partial<T>): Promise<T[]> {
    try {
      let query = this.db.from(this.table).update(data)

      Object.entries(filters).forEach(([key, value]) => {
        query = query.eq(key, value)
      })

      const { data: result, error } = await query.select()

      if (error) throw error
      return (result || []) as T[]
    } catch (error) {
      this.handleError('actualizar registros', error as Error)
      throw error
    }
  }

  /**
   * Elimina un registro por ID
   */
  async delete(id: string | number): Promise<boolean> {
    try {
      const { error } = await this.db
        .from(this.table)
        .delete()
        .eq('id', id)

      if (error) throw error
      return true
    } catch (error) {
      this.handleError('eliminar registro', error as Error)
      throw error
    }
  }

  /**
   * Elimina múltiples registros con un filtro
   */
  async deleteWhere(filters: Record<string, unknown>): Promise<boolean> {
    try {
      let query = this.db.from(this.table).delete()

      Object.entries(filters).forEach(([key, value]) => {
        query = query.eq(key, value)
      })

      const { error } = await query

      if (error) throw error
      return true
    } catch (error) {
      this.handleError('eliminar registros', error as Error)
      throw error
    }
  }

  /**
   * Ejecuta una función RPC de Supabase con fallback
   */
  async rpc<R>(functionName: string, params: Record<string, unknown> = {}, fallback: (() => Promise<R>) | null = null): Promise<R> {
    try {
      const { data, error } = await this.db.rpc(functionName, params)

      if (error) {
        if (fallback) {
          console.warn(`RPC ${functionName} falló, usando fallback:`, error.message)
          return await fallback()
        }
        throw error
      }

      return data as R
    } catch (error) {
      if (fallback) {
        console.warn(`RPC ${functionName} error, usando fallback:`, (error as Error).message)
        return await fallback()
      }
      this.handleError(`ejecutar ${functionName}`, error as Error)
      throw error
    }
  }

  /**
   * Cuenta registros con filtros opcionales
   */
  async count(filters: Record<string, unknown> = {}): Promise<number> {
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
      this.handleError('contar registros', error as Error)
      return 0
    }
  }

  /**
   * Verifica si existe un registro
   */
  async exists(filters: Record<string, unknown>): Promise<boolean> {
    const count = await this.count(filters)
    return count > 0
  }

  /**
   * Query personalizada
   */
  async query<R>(queryBuilder: (query: ReturnType<typeof this.db.from>) => Promise<{ data: R | null; error: Error | null }>): Promise<R | null> {
    try {
      const baseQuery = this.db.from(this.table)
      const { data, error } = await queryBuilder(baseQuery)

      if (error) throw error
      return data
    } catch (error) {
      this.handleError('ejecutar query', error as Error)
      throw error
    }
  }

  /**
   * Maneja errores de forma consistente
   */
  protected handleError(operation: string, error: Error): void {
    const message = `Error al ${operation} en ${this.table}: ${error.message}`
    console.error(message, error)
    notifyError(message)
  }
}

export default BaseService

/**
 * BaseService - Servicio base con operaciones CRUD genéricas
 *
 * Elimina la duplicación de código presente en los hooks de Supabase
 * proporcionando una interfaz consistente para operaciones de base de datos.
 *
 * NOTA SOBRE CACHE:
 * - Para componentes React, usar TanStack Query (hooks/queries/) que ya tiene cache optimizado
 * - El cache de BaseService es para operaciones que NO pasan por TanStack Query
 */

import { supabase, notifyError } from '../../hooks/supabase/base'
import type { SupabaseClient } from '@supabase/supabase-js'

// Type for filter builder - using generic type to avoid importing non-exported types
type FilterBuilder = ReturnType<ReturnType<SupabaseClient['from']>['select']>;

// =============================================================================
// CACHE LAYER
// =============================================================================

interface CacheEntry<T> {
  data: T;
  timestamp: number;
  ttl: number;
}

interface CacheStats {
  hits: number;
  misses: number;
  size: number;
}

/**
 * Cache en memoria con TTL (Time To Live)
 * Diseñado para operaciones que no pasan por TanStack Query
 */
class MemoryCache {
  private cache = new Map<string, CacheEntry<unknown>>();
  private stats: CacheStats = { hits: 0, misses: 0, size: 0 };

  /**
   * Obtiene un valor del cache si existe y no ha expirado
   */
  get<T>(key: string): T | null {
    const entry = this.cache.get(key) as CacheEntry<T> | undefined;

    if (!entry) {
      this.stats.misses++;
      return null;
    }

    // Verificar si expiró
    if (Date.now() - entry.timestamp > entry.ttl) {
      this.cache.delete(key);
      this.stats.size = this.cache.size;
      this.stats.misses++;
      return null;
    }

    this.stats.hits++;
    return entry.data;
  }

  /**
   * Guarda un valor en el cache con TTL
   */
  set<T>(key: string, data: T, ttl: number): void {
    this.cache.set(key, {
      data,
      timestamp: Date.now(),
      ttl
    });
    this.stats.size = this.cache.size;
  }

  /**
   * Invalida entradas que coincidan con un patrón
   * @param pattern - Prefijo de las keys a invalidar (ej: "clientes")
   */
  invalidate(pattern?: string): void {
    if (!pattern) {
      this.cache.clear();
    } else {
      for (const key of this.cache.keys()) {
        if (key.startsWith(pattern)) {
          this.cache.delete(key);
        }
      }
    }
    this.stats.size = this.cache.size;
  }

  /**
   * Obtiene estadísticas del cache
   */
  getStats(): CacheStats {
    return { ...this.stats };
  }

  /**
   * Limpia entradas expiradas (para mantenimiento)
   */
  cleanup(): void {
    const now = Date.now();
    for (const [key, entry] of this.cache.entries()) {
      if (now - entry.timestamp > entry.ttl) {
        this.cache.delete(key);
      }
    }
    this.stats.size = this.cache.size;
  }
}

// Instancia global del cache
const globalCache = new MemoryCache();

// =============================================================================
// TYPES
// =============================================================================

export interface FilterWithOperator {
  operator: string;
  value: unknown;
}

export interface BaseServiceOptions {
  orderBy?: string;
  ascending?: boolean;
  selectQuery?: string;
  /** TTL por defecto para cache (en ms). 0 = sin cache */
  defaultCacheTTL?: number;
}

export interface GetAllOptions {
  orderBy?: string;
  ascending?: boolean;
  selectQuery?: string;
  filters?: Record<string, unknown | FilterWithOperator>;
}

export interface CacheOptions {
  /** TTL en milisegundos (default: usar defaultCacheTTL del servicio) */
  ttl?: number;
  /** Forzar refresh ignorando cache */
  forceRefresh?: boolean;
  /** Key personalizada para el cache */
  cacheKey?: string;
}

export interface GetAllWithCacheOptions extends GetAllOptions, CacheOptions {}

export interface CreateOptions {
  returnData?: boolean;
}

export class BaseService<T = Record<string, unknown>> {
  protected table: string;
  protected db: SupabaseClient;
  protected orderBy: string;
  protected ascending: boolean;
  protected selectQuery: string;
  protected defaultCacheTTL: number;
  protected cache: MemoryCache;

  constructor(tableName: string, options: BaseServiceOptions = {}) {
    this.table = tableName
    this.db = supabase
    this.orderBy = options.orderBy || 'id'
    this.ascending = options.ascending !== false
    this.selectQuery = options.selectQuery || '*'
    this.defaultCacheTTL = options.defaultCacheTTL || 0 // 0 = sin cache por defecto
    this.cache = globalCache
  }

  // ===========================================================================
  // CACHE HELPERS
  // ===========================================================================

  /**
   * Genera una key de cache única basada en la tabla y opciones
   */
  protected generateCacheKey(operation: string, options?: Record<string, unknown>): string {
    const base = `${this.table}:${operation}`
    if (!options || Object.keys(options).length === 0) {
      return base
    }
    // Hash simple de las opciones
    const optionsStr = JSON.stringify(options, Object.keys(options).sort())
    return `${base}:${this.simpleHash(optionsStr)}`
  }

  /**
   * Hash simple para generar keys de cache
   */
  private simpleHash(str: string): string {
    let hash = 0
    for (let i = 0; i < str.length; i++) {
      const char = str.charCodeAt(i)
      hash = ((hash << 5) - hash) + char
      hash = hash & hash
    }
    return Math.abs(hash).toString(36)
  }

  /**
   * Invalida el cache de esta tabla
   */
  invalidateCache(): void {
    this.cache.invalidate(this.table)
  }

  /**
   * Obtiene estadísticas del cache global
   */
  getCacheStats(): CacheStats {
    return this.cache.getStats()
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
   * Obtiene todos los registros con cache opcional
   *
   * NOTA: Para componentes React, preferir TanStack Query (hooks/queries/)
   * Este método es para operaciones que NO pasan por React Query.
   *
   * @example
   * // Con cache de 5 minutos
   * const data = await service.getAllCached({ ttl: 5 * 60 * 1000 })
   *
   * // Forzar refresh
   * const freshData = await service.getAllCached({ forceRefresh: true })
   */
  async getAllCached(options: GetAllWithCacheOptions = {}): Promise<T[]> {
    const {
      ttl = this.defaultCacheTTL,
      forceRefresh = false,
      cacheKey,
      ...getAllOptions
    } = options

    // Si no hay TTL, usar getAll normal
    if (ttl <= 0) {
      return this.getAll(getAllOptions)
    }

    const key = cacheKey || this.generateCacheKey('getAll', getAllOptions)

    // Intentar obtener del cache
    if (!forceRefresh) {
      const cached = this.cache.get<T[]>(key)
      if (cached !== null) {
        return cached
      }
    }

    // Obtener de la base de datos
    const data = await this.getAll(getAllOptions)

    // Guardar en cache
    this.cache.set(key, data, ttl)

    return data
  }

  /**
   * Obtiene un registro por ID con cache opcional
   */
  async getByIdCached(id: string | number, options: CacheOptions = {}): Promise<T | null> {
    const {
      ttl = this.defaultCacheTTL,
      forceRefresh = false,
      cacheKey
    } = options

    // Si no hay TTL, usar getById normal
    if (ttl <= 0) {
      return this.getById(id)
    }

    const key = cacheKey || this.generateCacheKey('getById', { id })

    // Intentar obtener del cache
    if (!forceRefresh) {
      const cached = this.cache.get<T>(key)
      if (cached !== null) {
        return cached
      }
    }

    // Obtener de la base de datos
    const data = await this.getById(id)

    // Guardar en cache si existe
    if (data) {
      this.cache.set(key, data, ttl)
    }

    return data
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
   * Invalida automáticamente el cache de esta tabla
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

        // Invalidar cache después de crear
        this.invalidateCache()

        return result as T
      } else {
        const { error } = await this.db.from(this.table).insert([data])
        if (error) throw error

        // Invalidar cache después de crear
        this.invalidateCache()

        return true
      }
    } catch (error) {
      this.handleError('crear registro', error as Error)
      throw error // Re-throw para que el llamador pueda manejar el error
    }
  }

  /**
   * Crea múltiples registros
   * Invalida automáticamente el cache de esta tabla
   */
  async createMany(items: Partial<T>[]): Promise<T[]> {
    try {
      const { data, error } = await this.db
        .from(this.table)
        .insert(items)
        .select()

      if (error) throw error

      // Invalidar cache después de crear
      this.invalidateCache()

      return (data || []) as T[]
    } catch (error) {
      this.handleError('crear registros', error as Error)
      throw error
    }
  }

  /**
   * Actualiza un registro por ID
   * Invalida automáticamente el cache de esta tabla
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

      // Invalidar cache después de actualizar
      this.invalidateCache()

      return result as T
    } catch (error) {
      this.handleError('actualizar registro', error as Error)
      throw error
    }
  }

  /**
   * Actualiza múltiples registros con un filtro
   * Invalida automáticamente el cache de esta tabla
   */
  async updateWhere(filters: Record<string, unknown>, data: Partial<T>): Promise<T[]> {
    try {
      let query = this.db.from(this.table).update(data)

      Object.entries(filters).forEach(([key, value]) => {
        query = query.eq(key, value)
      })

      const { data: result, error } = await query.select()

      if (error) throw error

      // Invalidar cache después de actualizar
      this.invalidateCache()

      return (result || []) as T[]
    } catch (error) {
      this.handleError('actualizar registros', error as Error)
      throw error
    }
  }

  /**
   * Elimina un registro por ID
   * Invalida automáticamente el cache de esta tabla
   */
  async delete(id: string | number): Promise<boolean> {
    try {
      const { error } = await this.db
        .from(this.table)
        .delete()
        .eq('id', id)

      if (error) throw error

      // Invalidar cache después de eliminar
      this.invalidateCache()

      return true
    } catch (error) {
      this.handleError('eliminar registro', error as Error)
      throw error
    }
  }

  /**
   * Elimina múltiples registros con un filtro
   * Invalida automáticamente el cache de esta tabla
   */
  async deleteWhere(filters: Record<string, unknown>): Promise<boolean> {
    try {
      let query = this.db.from(this.table).delete()

      Object.entries(filters).forEach(([key, value]) => {
        query = query.eq(key, value)
      })

      const { error } = await query

      if (error) throw error

      // Invalidar cache después de eliminar
      this.invalidateCache()

      return true
    } catch (error) {
      this.handleError('eliminar registros', error as Error)
      throw error
    }
  }

  /**
   * Ejecuta una función RPC de Supabase
   *
   * IMPORTANTE: Las RPCs son transacciones atómicas en PostgreSQL.
   * Si fallan, es por una razón válida (constraint, permisos, etc.).
   * NO usar fallbacks manuales ya que rompen la atomicidad.
   */
  async rpc<R>(functionName: string, params: Record<string, unknown> = {}): Promise<R> {
    try {
      const { data, error } = await this.db.rpc(functionName, params)

      if (error) {
        // Log detallado para debugging
        console.error(`[RPC Error] ${functionName}:`, {
          code: error.code,
          message: error.message,
          details: error.details,
          hint: error.hint
        })
        throw new Error(`Error en operación ${functionName}: ${error.message}`)
      }

      return data as R
    } catch (error) {
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

// =============================================================================
// EXPORTS ADICIONALES
// =============================================================================

/**
 * Invalida todo el cache global
 * Útil al cerrar sesión o en situaciones de emergencia
 */
export function invalidateAllCache(): void {
  globalCache.invalidate()
}

/**
 * Obtiene estadísticas del cache global
 */
export function getGlobalCacheStats(): CacheStats {
  return globalCache.getStats()
}

/**
 * Limpia entradas expiradas del cache
 * Llamar periódicamente para liberar memoria
 */
export function cleanupCache(): void {
  globalCache.cleanup()
}

export default BaseService

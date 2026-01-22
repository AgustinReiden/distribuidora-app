/**
 * useService - Hook para manejar operaciones de servicio con estado
 *
 * Proporciona:
 * - Estado de carga automático
 * - Manejo de errores
 * - Caché opcional
 * - Reintentos con backoff
 * - Optimistic updates
 */

import { useState, useCallback, useRef, useEffect } from 'react'
import { categorizeError } from '../utils/errorUtils'
import type { ErrorCategory } from '@/types'

/**
 * Estados posibles de una operación
 */
export const ServiceStatus = {
  IDLE: 'idle',
  LOADING: 'loading',
  SUCCESS: 'success',
  ERROR: 'error'
} as const

export type ServiceStatusType = typeof ServiceStatus[keyof typeof ServiceStatus]

/**
 * Estado interno del servicio
 */
interface ServiceState<T> {
  data: T | null
  status: ServiceStatusType
  error: Error | null
  errorCategory: ErrorCategory | null
}

/**
 * Opciones de configuración para useService
 */
export interface UseServiceOptions<T> {
  /** Ejecutar inmediatamente al montar */
  immediate?: boolean
  /** Datos iniciales */
  initialData?: T | null
  /** Callback al completar exitosamente */
  onSuccess?: (data: T) => void
  /** Callback al ocurrir un error */
  onError?: (error: Error, category: ErrorCategory) => void
  /** Número de reintentos */
  retries?: number
  /** Delay base entre reintentos (ms) */
  retryDelay?: number
  /** Clave para caché */
  cacheKey?: string
  /** TTL del caché en ms (default: 5 min) */
  cacheTTL?: number
}

/**
 * Resultado del hook useService
 */
export interface UseServiceResult<T, TArgs extends unknown[] = unknown[]> {
  /** Datos obtenidos */
  data: T | null
  /** Estado actual de la operación */
  status: ServiceStatusType
  /** Error si ocurrió alguno */
  error: Error | null
  /** Categoría del error */
  errorCategory: ErrorCategory | null
  /** Si está cargando */
  loading: boolean
  /** Si está en estado idle */
  isIdle: boolean
  /** Si completó exitosamente */
  isSuccess: boolean
  /** Si hay error */
  isError: boolean
  /** Ejecuta la operación */
  execute: (...args: TArgs) => Promise<T>
  /** Resetea el estado */
  reset: () => void
  /** Actualiza los datos manualmente */
  setData: (data: T | ((prev: T | null) => T)) => void
  /** Invalida el caché */
  invalidateCache: (key?: string) => void
}

/**
 * Entrada de caché
 */
interface CacheEntry<T> {
  data: T
  timestamp: number
}

/**
 * Hook para manejar una operación de servicio
 *
 * @param serviceFn - Función del servicio a ejecutar
 * @param options - Opciones de configuración
 * @returns Estado y funciones de control
 *
 * @example
 * const { data, loading, error, execute } = useService(
 *   () => clienteService.getAll(),
 *   { immediate: true }
 * )
 */
export function useService<T, TArgs extends unknown[] = unknown[]>(
  serviceFn: (...args: TArgs) => Promise<T>,
  options: UseServiceOptions<T> = {}
): UseServiceResult<T, TArgs> {
  const {
    immediate = false,
    initialData = null,
    onSuccess,
    onError,
    retries = 0,
    retryDelay = 1000,
    cacheKey,
    cacheTTL = 5 * 60 * 1000 // 5 minutos
  } = options

  const [state, setState] = useState<ServiceState<T>>({
    data: initialData,
    status: ServiceStatus.IDLE,
    error: null,
    errorCategory: null
  })

  const mountedRef = useRef<boolean>(true)
  const cacheRef = useRef<Map<string, CacheEntry<T>>>(new Map())
  const retryCountRef = useRef<number>(0)

  // Limpiar al desmontar
  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  /**
   * Obtiene datos del caché si están disponibles y válidos
   */
  const getFromCache = useCallback((key: string | undefined): T | null => {
    if (!key) return null

    const cached = cacheRef.current.get(key)
    if (!cached) return null

    const isExpired = Date.now() - cached.timestamp > cacheTTL
    if (isExpired) {
      cacheRef.current.delete(key)
      return null
    }

    return cached.data
  }, [cacheTTL])

  /**
   * Guarda datos en caché
   */
  const saveToCache = useCallback((key: string | undefined, data: T): void => {
    if (!key) return

    cacheRef.current.set(key, {
      data,
      timestamp: Date.now()
    })
  }, [])

  /**
   * Ejecuta la operación del servicio
   */
  const execute = useCallback(async (...args: TArgs): Promise<T> => {
    // Verificar caché primero
    const cachedData = getFromCache(cacheKey)
    if (cachedData) {
      setState({
        data: cachedData,
        status: ServiceStatus.SUCCESS,
        error: null,
        errorCategory: null
      })
      return cachedData
    }

    setState(prev => ({
      ...prev,
      status: ServiceStatus.LOADING,
      error: null,
      errorCategory: null
    }))

    try {
      const result = await serviceFn(...args)

      if (!mountedRef.current) return result

      // Guardar en caché
      saveToCache(cacheKey, result)

      setState({
        data: result,
        status: ServiceStatus.SUCCESS,
        error: null,
        errorCategory: null
      })

      retryCountRef.current = 0
      onSuccess?.(result)

      return result
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err))

      // Reintentar si es posible
      if (retryCountRef.current < retries) {
        retryCountRef.current++
        const delay = retryDelay * Math.pow(2, retryCountRef.current - 1)

        await new Promise(resolve => setTimeout(resolve, delay))

        if (mountedRef.current) {
          return execute(...args)
        }
      }

      if (!mountedRef.current) throw error

      const category = categorizeError(error)

      setState(prev => ({
        ...prev,
        status: ServiceStatus.ERROR,
        error,
        errorCategory: category
      }))

      retryCountRef.current = 0
      onError?.(error, category)

      throw error
    }
  }, [serviceFn, cacheKey, getFromCache, saveToCache, retries, retryDelay, onSuccess, onError])

  /**
   * Resetea el estado
   */
  const reset = useCallback((): void => {
    setState({
      data: initialData,
      status: ServiceStatus.IDLE,
      error: null,
      errorCategory: null
    })
    retryCountRef.current = 0
  }, [initialData])

  /**
   * Invalida el caché
   */
  const invalidateCache = useCallback((key: string | undefined = cacheKey): void => {
    if (key) {
      cacheRef.current.delete(key)
    } else {
      cacheRef.current.clear()
    }
  }, [cacheKey])

  /**
   * Actualiza los datos manualmente (optimistic update)
   */
  const setData = useCallback((newData: T | ((prev: T | null) => T)): void => {
    setState(prev => ({
      ...prev,
      data: typeof newData === 'function' ? (newData as (prev: T | null) => T)(prev.data) : newData
    }))
  }, [])

  // Ejecutar inmediatamente si se especifica (solo al montar)
  const immediateRef = useRef<boolean>(immediate)
  useEffect(() => {
    if (immediateRef.current) {
      execute(...([] as unknown as TArgs))
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return {
    data: state.data,
    status: state.status,
    error: state.error,
    errorCategory: state.errorCategory,
    loading: state.status === ServiceStatus.LOADING,
    isIdle: state.status === ServiceStatus.IDLE,
    isSuccess: state.status === ServiceStatus.SUCCESS,
    isError: state.status === ServiceStatus.ERROR,
    execute,
    reset,
    setData,
    invalidateCache
  }
}

/**
 * Tipo para el mapa de servicios
 */
type ServiceFunctions = Record<string, (...args: unknown[]) => Promise<unknown>>

/**
 * Resultado de useServices
 */
type UseServicesResult<T extends ServiceFunctions> = {
  [K in keyof T]: UseServiceResult<Awaited<ReturnType<T[K]>>, Parameters<T[K]>>
}

/**
 * Hook para manejar múltiples operaciones de servicio
 *
 * @param services - Mapa de servicios { nombre: serviceFn }
 * @returns Estado y funciones para cada servicio
 *
 * @example
 * const { clientes, productos } = useServices({
 *   clientes: () => clienteService.getAll(),
 *   productos: () => productoService.getAll()
 * })
 */
export function useServices<T extends ServiceFunctions>(services: T): UseServicesResult<T> {
  const results = {} as UseServicesResult<T>

  Object.entries(services).forEach(([key, serviceFn]) => {
    // eslint-disable-next-line react-hooks/rules-of-hooks
    results[key as keyof T] = useService(serviceFn) as UseServicesResult<T>[keyof T]
  })

  return results
}

/**
 * Opciones para useMutation
 */
export interface UseMutationOptions<TData, TArgs extends unknown[]> {
  /** Callback al completar exitosamente */
  onSuccess?: (data: TData, ...args: TArgs) => void
  /** Callback al ocurrir un error */
  onError?: (error: Error, ...args: TArgs) => void
  /** Callback al finalizar (éxito o error) */
  onSettled?: (data: TData | null, error: Error | null, ...args: TArgs) => void
}

/**
 * Estado de la mutación
 */
interface MutationState<TData> {
  status: ServiceStatusType
  error: Error | null
  data: TData | null
}

/**
 * Resultado del hook useMutation
 */
export interface UseMutationResult<TData, TArgs extends unknown[]> {
  /** Ejecuta la mutación */
  mutate: (...args: TArgs) => Promise<TData>
  /** Resetea el estado */
  reset: () => void
  /** Datos obtenidos */
  data: TData | null
  /** Error si ocurrió alguno */
  error: Error | null
  /** Estado actual */
  status: ServiceStatusType
  /** Si está cargando */
  loading: boolean
  /** Si está en estado idle */
  isIdle: boolean
  /** Si completó exitosamente */
  isSuccess: boolean
  /** Si hay error */
  isError: boolean
}

/**
 * Hook para manejar mutaciones (create, update, delete)
 *
 * @param mutationFn - Función de mutación
 * @param options - Opciones
 * @returns Estado y función de mutación
 *
 * @example
 * const { mutate, loading } = useMutation(
 *   (data) => clienteService.create(data),
 *   { onSuccess: () => refetch() }
 * )
 */
export function useMutation<TData, TArgs extends unknown[] = unknown[]>(
  mutationFn: (...args: TArgs) => Promise<TData>,
  options: UseMutationOptions<TData, TArgs> = {}
): UseMutationResult<TData, TArgs> {
  const {
    onSuccess,
    onError,
    onSettled
  } = options

  const [state, setState] = useState<MutationState<TData>>({
    status: ServiceStatus.IDLE,
    error: null,
    data: null
  })

  const mountedRef = useRef<boolean>(true)

  useEffect(() => {
    return () => {
      mountedRef.current = false
    }
  }, [])

  const mutate = useCallback(async (...args: TArgs): Promise<TData> => {
    setState({
      status: ServiceStatus.LOADING,
      error: null,
      data: null
    })

    try {
      const result = await mutationFn(...args)

      if (!mountedRef.current) return result

      setState({
        status: ServiceStatus.SUCCESS,
        error: null,
        data: result
      })

      onSuccess?.(result, ...args)
      onSettled?.(result, null, ...args)

      return result
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err))

      if (!mountedRef.current) throw error

      setState({
        status: ServiceStatus.ERROR,
        error,
        data: null
      })

      onError?.(error, ...args)
      onSettled?.(null, error, ...args)

      throw error
    }
  }, [mutationFn, onSuccess, onError, onSettled])

  const reset = useCallback((): void => {
    setState({
      status: ServiceStatus.IDLE,
      error: null,
      data: null
    })
  }, [])

  return {
    mutate,
    reset,
    data: state.data,
    error: state.error,
    status: state.status,
    loading: state.status === ServiceStatus.LOADING,
    isIdle: state.status === ServiceStatus.IDLE,
    isSuccess: state.status === ServiceStatus.SUCCESS,
    isError: state.status === ServiceStatus.ERROR
  }
}

/**
 * Opciones para usePolling
 */
export interface UsePollingOptions<T> extends UseServiceOptions<T> {
  /** Si el polling está habilitado */
  enabled?: boolean
}

/**
 * Hook para polling periódico de datos
 *
 * @param serviceFn - Función del servicio
 * @param interval - Intervalo en ms
 * @param options - Opciones adicionales
 */
export function usePolling<T, TArgs extends unknown[] = unknown[]>(
  serviceFn: (...args: TArgs) => Promise<T>,
  interval: number,
  options: UsePollingOptions<T> = {}
): UseServiceResult<T, TArgs> {
  const { enabled = true, ...serviceOptions } = options
  const service = useService<T, TArgs>(serviceFn, serviceOptions)
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null)
  const executeRef = useRef(service.execute)

  // Mantener referencia actualizada
  useEffect(() => {
    executeRef.current = service.execute
  }, [service.execute])

  useEffect(() => {
    if (!enabled) {
      if (intervalRef.current) {
        clearInterval(intervalRef.current)
        intervalRef.current = null
      }
      return
    }

    // Ejecutar inmediatamente
    executeRef.current(...([] as unknown as TArgs))

    // Configurar polling
    intervalRef.current = setInterval(() => {
      executeRef.current(...([] as unknown as TArgs))
    }, interval)

    return () => {
      if (intervalRef.current) {
        clearInterval(intervalRef.current)
      }
    }
  }, [enabled, interval])

  return service
}

export default useService

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

/**
 * Estados posibles de una operación
 */
export const ServiceStatus = {
  IDLE: 'idle',
  LOADING: 'loading',
  SUCCESS: 'success',
  ERROR: 'error'
}

/**
 * Hook para manejar una operación de servicio
 *
 * @param {Function} serviceFn - Función del servicio a ejecutar
 * @param {Object} options - Opciones de configuración
 * @returns {Object} Estado y funciones de control
 *
 * @example
 * const { data, loading, error, execute } = useService(
 *   () => clienteService.getAll(),
 *   { immediate: true }
 * )
 */
export function useService(serviceFn, options = {}) {
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

  const [state, setState] = useState({
    data: initialData,
    status: ServiceStatus.IDLE,
    error: null,
    errorCategory: null
  })

  const mountedRef = useRef(true)
  const cacheRef = useRef(new Map())
  const retryCountRef = useRef(0)

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
  const getFromCache = useCallback((key) => {
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
  const saveToCache = useCallback((key, data) => {
    if (!key) return

    cacheRef.current.set(key, {
      data,
      timestamp: Date.now()
    })
  }, [])

  /**
   * Ejecuta la operación del servicio
   */
  const execute = useCallback(async (...args) => {
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
      // Reintentar si es posible
      if (retryCountRef.current < retries) {
        retryCountRef.current++
        const delay = retryDelay * Math.pow(2, retryCountRef.current - 1)

        await new Promise(resolve => setTimeout(resolve, delay))

        if (mountedRef.current) {
          return execute(...args)
        }
      }

      if (!mountedRef.current) throw err

      const category = categorizeError(err)

      setState(prev => ({
        ...prev,
        status: ServiceStatus.ERROR,
        error: err,
        errorCategory: category
      }))

      retryCountRef.current = 0
      onError?.(err, category)

      throw err
    }
  }, [serviceFn, cacheKey, getFromCache, saveToCache, retries, retryDelay, onSuccess, onError])

  /**
   * Resetea el estado
   */
  const reset = useCallback(() => {
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
  const invalidateCache = useCallback((key = cacheKey) => {
    if (key) {
      cacheRef.current.delete(key)
    } else {
      cacheRef.current.clear()
    }
  }, [cacheKey])

  /**
   * Actualiza los datos manualmente (optimistic update)
   */
  const setData = useCallback((newData) => {
    setState(prev => ({
      ...prev,
      data: typeof newData === 'function' ? newData(prev.data) : newData
    }))
  }, [])

  // Ejecutar inmediatamente si se especifica (solo al montar)
  const immediateRef = useRef(immediate)
  useEffect(() => {
    if (immediateRef.current) {
      execute()
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
 * Hook para manejar múltiples operaciones de servicio
 *
 * @param {Object} services - Mapa de servicios { nombre: serviceFn }
 * @returns {Object} Estado y funciones para cada servicio
 *
 * @example
 * const { clientes, productos } = useServices({
 *   clientes: () => clienteService.getAll(),
 *   productos: () => productoService.getAll()
 * })
 */
export function useServices(services) {
  const results = {}

  Object.entries(services).forEach(([key, serviceFn]) => {
    // eslint-disable-next-line react-hooks/rules-of-hooks
    results[key] = useService(serviceFn)
  })

  return results
}

/**
 * Hook para manejar mutaciones (create, update, delete)
 *
 * @param {Function} mutationFn - Función de mutación
 * @param {Object} options - Opciones
 * @returns {Object} Estado y función de mutación
 *
 * @example
 * const { mutate, loading } = useMutation(
 *   (data) => clienteService.create(data),
 *   { onSuccess: () => refetch() }
 * )
 */
export function useMutation(mutationFn, options = {}) {
  const {
    onSuccess,
    onError,
    onSettled
  } = options

  const [state, setState] = useState({
    status: ServiceStatus.IDLE,
    error: null,
    data: null
  })

  const mountedRef = useRef(true)

  useEffect(() => {
    return () => {
      mountedRef.current = false
    }
  }, [])

  const mutate = useCallback(async (...args) => {
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
      if (!mountedRef.current) throw err

      setState({
        status: ServiceStatus.ERROR,
        error: err,
        data: null
      })

      onError?.(err, ...args)
      onSettled?.(null, err, ...args)

      throw err
    }
  }, [mutationFn, onSuccess, onError, onSettled])

  const reset = useCallback(() => {
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
 * Hook para polling periódico de datos
 *
 * @param {Function} serviceFn - Función del servicio
 * @param {number} interval - Intervalo en ms
 * @param {Object} options - Opciones adicionales
 */
export function usePolling(serviceFn, interval, options = {}) {
  const { enabled = true, ...serviceOptions } = options
  const service = useService(serviceFn, serviceOptions)
  const intervalRef = useRef(null)
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
    executeRef.current()

    // Configurar polling
    intervalRef.current = setInterval(() => {
      executeRef.current()
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

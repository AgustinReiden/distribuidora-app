/**
 * Hook genérico para operaciones async con estado de carga y error
 * @module hooks/useAsync
 */
import { useState, useCallback, useRef, useEffect } from 'react'

/**
 * @typedef {Object} AsyncState
 * @property {any} data - Los datos obtenidos
 * @property {boolean} loading - Si está cargando
 * @property {Error|null} error - Error si ocurrió alguno
 */

/**
 * @typedef {Object} AsyncActions
 * @property {Function} execute - Ejecuta la función async
 * @property {Function} reset - Resetea el estado
 * @property {Function} setData - Actualiza los datos manualmente
 */

/**
 * Hook para manejar operaciones async con estado de carga y error
 *
 * @param {Function} asyncFunction - Función async a ejecutar
 * @param {Object} options - Opciones de configuración
 * @param {boolean} [options.immediate=false] - Ejecutar inmediatamente al montar
 * @param {any} [options.initialData=null] - Datos iniciales
 * @param {Function} [options.onSuccess] - Callback al completar exitosamente
 * @param {Function} [options.onError] - Callback al ocurrir un error
 * @returns {[AsyncState, AsyncActions]}
 *
 * @example
 * const fetchUsers = async () => {
 *   const response = await api.getUsers()
 *   return response.data
 * }
 *
 * const [{ data, loading, error }, { execute }] = useAsync(fetchUsers, {
 *   immediate: true,
 *   onSuccess: (data) => console.log('Loaded', data.length, 'users')
 * })
 */
export function useAsync(asyncFunction, options = {}) {
  const {
    immediate = false,
    initialData = null,
    onSuccess,
    onError
  } = options

  const [state, setState] = useState({
    data: initialData,
    loading: immediate,
    error: null
  })

  const mountedRef = useRef(true)
  const lastCallRef = useRef(0)

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  const execute = useCallback(async (...args) => {
    const callId = ++lastCallRef.current

    setState(prev => ({ ...prev, loading: true, error: null }))

    try {
      const data = await asyncFunction(...args)

      // Solo actualizar si es la última llamada y el componente sigue montado
      if (mountedRef.current && callId === lastCallRef.current) {
        setState({ data, loading: false, error: null })
        onSuccess?.(data)
      }

      return data
    } catch (error) {
      if (mountedRef.current && callId === lastCallRef.current) {
        setState(prev => ({ ...prev, loading: false, error }))
        onError?.(error)
      }
      throw error
    }
  }, [asyncFunction, onSuccess, onError])

  const reset = useCallback(() => {
    setState({ data: initialData, loading: false, error: null })
  }, [initialData])

  const setData = useCallback((data) => {
    setState(prev => ({ ...prev, data }))
  }, [])

  useEffect(() => {
    if (immediate) {
      execute()
    }
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  return [state, { execute, reset, setData }]
}

/**
 * Hook para debounce de valores
 *
 * @param {any} value - Valor a debounce
 * @param {number} [delay=300] - Delay en ms
 * @returns {any} Valor con debounce aplicado
 *
 * @example
 * const [search, setSearch] = useState('')
 * const debouncedSearch = useDebounce(search, 500)
 *
 * useEffect(() => {
 *   if (debouncedSearch) {
 *     fetchResults(debouncedSearch)
 *   }
 * }, [debouncedSearch])
 */
export function useDebounce(value, delay = 300) {
  const [debouncedValue, setDebouncedValue] = useState(value)

  useEffect(() => {
    const timer = setTimeout(() => {
      setDebouncedValue(value)
    }, delay)

    return () => clearTimeout(timer)
  }, [value, delay])

  return debouncedValue
}

/**
 * Hook para detectar clics fuera de un elemento
 *
 * @param {Function} handler - Función a ejecutar cuando se hace clic fuera
 * @returns {React.RefObject} Ref para asignar al elemento
 *
 * @example
 * const [isOpen, setIsOpen] = useState(false)
 * const ref = useClickOutside(() => setIsOpen(false))
 *
 * return (
 *   <div ref={ref}>
 *     {isOpen && <Dropdown />}
 *   </div>
 * )
 */
export function useClickOutside(handler) {
  const ref = useRef(null)

  useEffect(() => {
    const listener = (event) => {
      if (!ref.current || ref.current.contains(event.target)) {
        return
      }
      handler(event)
    }

    document.addEventListener('mousedown', listener)
    document.addEventListener('touchstart', listener)

    return () => {
      document.removeEventListener('mousedown', listener)
      document.removeEventListener('touchstart', listener)
    }
  }, [handler])

  return ref
}

/**
 * Hook para manejar estado de toggle
 *
 * @param {boolean} [initialValue=false] - Valor inicial
 * @returns {[boolean, Function, Function, Function]} [value, toggle, setTrue, setFalse]
 *
 * @example
 * const [isOpen, toggle, open, close] = useToggle(false)
 */
export function useToggle(initialValue = false) {
  const [value, setValue] = useState(initialValue)

  const toggle = useCallback(() => setValue(v => !v), [])
  const setTrue = useCallback(() => setValue(true), [])
  const setFalse = useCallback(() => setValue(false), [])

  return [value, toggle, setTrue, setFalse]
}

/**
 * Hook para persistir estado en localStorage
 *
 * @param {string} key - Clave de localStorage
 * @param {any} initialValue - Valor inicial si no existe en storage
 * @returns {[any, Function]} [value, setValue]
 *
 * @example
 * const [theme, setTheme] = useLocalStorage('theme', 'light')
 */
export function useLocalStorage(key, initialValue) {
  const [storedValue, setStoredValue] = useState(() => {
    try {
      const item = window.localStorage.getItem(key)
      return item ? JSON.parse(item) : initialValue
    } catch (error) {
      console.warn(`Error reading localStorage key "${key}":`, error)
      return initialValue
    }
  })

  const setValue = useCallback((value) => {
    try {
      const valueToStore = value instanceof Function ? value(storedValue) : value
      setStoredValue(valueToStore)
      window.localStorage.setItem(key, JSON.stringify(valueToStore))
    } catch (error) {
      console.warn(`Error setting localStorage key "${key}":`, error)
    }
  }, [key, storedValue])

  return [storedValue, setValue]
}

export default useAsync

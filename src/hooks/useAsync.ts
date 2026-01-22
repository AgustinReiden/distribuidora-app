/**
 * Hook generico para operaciones async con estado de carga y error
 * @module hooks/useAsync
 */
import { useState, useCallback, useRef, useEffect, type RefObject, type Dispatch, type SetStateAction } from 'react'

/**
 * Estado de una operación async
 */
export interface AsyncState<T> {
  /** Los datos obtenidos */
  data: T | null
  /** Si está cargando */
  loading: boolean
  /** Error si ocurrió alguno */
  error: Error | null
}

/**
 * Acciones disponibles para una operación async
 */
export interface AsyncActions<T, TArgs extends unknown[]> {
  /** Ejecuta la función async */
  execute: (...args: TArgs) => Promise<T>
  /** Resetea el estado */
  reset: () => void
  /** Actualiza los datos manualmente */
  setData: (data: T | null) => void
}

/**
 * Opciones de configuración para useAsync
 */
export interface UseAsyncOptions<T> {
  /** Ejecutar inmediatamente al montar (default: false) */
  immediate?: boolean
  /** Datos iniciales (default: null) */
  initialData?: T | null
  /** Callback al completar exitosamente */
  onSuccess?: (data: T) => void
  /** Callback al ocurrir un error */
  onError?: (error: Error) => void
}

/**
 * Resultado del hook useAsync
 */
export type UseAsyncResult<T, TArgs extends unknown[]> = [AsyncState<T>, AsyncActions<T, TArgs>]

/**
 * Hook para manejar operaciones async con estado de carga y error
 *
 * @param asyncFunction - Función async a ejecutar
 * @param options - Opciones de configuración
 * @returns [state, actions] - Tupla con el estado y las acciones
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
export function useAsync<T, TArgs extends unknown[] = []>(
  asyncFunction: (...args: TArgs) => Promise<T>,
  options: UseAsyncOptions<T> = {}
): UseAsyncResult<T, TArgs> {
  const {
    immediate = false,
    initialData = null,
    onSuccess,
    onError
  } = options

  const [state, setState] = useState<AsyncState<T>>({
    data: initialData,
    loading: immediate,
    error: null
  })

  const mountedRef = useRef<boolean>(true)
  const lastCallRef = useRef<number>(0)

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  const execute = useCallback(async (...args: TArgs): Promise<T> => {
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
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err))

      if (mountedRef.current && callId === lastCallRef.current) {
        setState(prev => ({ ...prev, loading: false, error }))
        onError?.(error)
      }
      throw error
    }
  }, [asyncFunction, onSuccess, onError])

  const reset = useCallback((): void => {
    setState({ data: initialData, loading: false, error: null })
  }, [initialData])

  const setData = useCallback((data: T | null): void => {
    setState(prev => ({ ...prev, data }))
  }, [])

  useEffect(() => {
    if (immediate) {
      execute(...([] as unknown as TArgs))
    }
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  return [state, { execute, reset, setData }]
}

/**
 * Hook para debounce de valores
 *
 * @param value - Valor a debounce
 * @param delay - Delay en ms (default: 300)
 * @returns Valor con debounce aplicado
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
export function useDebounce<T>(value: T, delay: number = 300): T {
  const [debouncedValue, setDebouncedValue] = useState<T>(value)

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
 * @param handler - Función a ejecutar cuando se hace clic fuera
 * @returns Ref para asignar al elemento
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
export function useClickOutside<T extends HTMLElement = HTMLDivElement>(
  handler: (event: MouseEvent | TouchEvent) => void
): RefObject<T> {
  const ref = useRef<T>(null)

  useEffect(() => {
    const listener = (event: MouseEvent | TouchEvent): void => {
      if (!ref.current || ref.current.contains(event.target as Node)) {
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
 * Resultado del hook useToggle
 */
export type UseToggleResult = [
  /** Valor actual */
  boolean,
  /** Función para alternar el valor */
  () => void,
  /** Función para establecer en true */
  () => void,
  /** Función para establecer en false */
  () => void
]

/**
 * Hook para manejar estado de toggle
 *
 * @param initialValue - Valor inicial (default: false)
 * @returns [value, toggle, setTrue, setFalse]
 *
 * @example
 * const [isOpen, toggle, open, close] = useToggle(false)
 */
export function useToggle(initialValue: boolean = false): UseToggleResult {
  const [value, setValue] = useState<boolean>(initialValue)

  const toggle = useCallback((): void => setValue(v => !v), [])
  const setTrue = useCallback((): void => setValue(true), [])
  const setFalse = useCallback((): void => setValue(false), [])

  return [value, toggle, setTrue, setFalse]
}

/**
 * Resultado del hook useLocalStorage
 */
export type UseLocalStorageResult<T> = [
  /** Valor almacenado */
  T,
  /** Función para actualizar el valor */
  Dispatch<SetStateAction<T>>
]

/**
 * Hook para persistir estado en localStorage
 *
 * @param key - Clave de localStorage
 * @param initialValue - Valor inicial si no existe en storage
 * @returns [value, setValue]
 *
 * @example
 * const [theme, setTheme] = useLocalStorage('theme', 'light')
 */
export function useLocalStorage<T>(key: string, initialValue: T): UseLocalStorageResult<T> {
  const [storedValue, setStoredValue] = useState<T>(() => {
    try {
      const item = window.localStorage.getItem(key)
      return item ? (JSON.parse(item) as T) : initialValue
    } catch (error) {
      console.warn(`Error reading localStorage key "${key}":`, error)
      return initialValue
    }
  })

  const setValue: Dispatch<SetStateAction<T>> = useCallback((value: SetStateAction<T>) => {
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

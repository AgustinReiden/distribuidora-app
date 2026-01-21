/* eslint-disable no-unused-vars */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'
import {
  useAsync,
  useDebounce,
  useToggle,
  useLocalStorage
} from './useAsync'

describe('useAsync', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('inicia con estado loading:false cuando immediate es false', () => {
    const asyncFn = vi.fn().mockResolvedValue('data')
    const { result } = renderHook(() => useAsync(asyncFn))

    expect(result.current[0].loading).toBe(false)
    expect(result.current[0].data).toBe(null)
    expect(result.current[0].error).toBe(null)
  })

  it('inicia con estado loading:true cuando immediate es true', async () => {
    const asyncFn = vi.fn().mockResolvedValue('data')
    const { result } = renderHook(() => useAsync(asyncFn, { immediate: true }))

    expect(result.current[0].loading).toBe(true)

    await act(async () => {
      await vi.runAllTimersAsync()
    })

    expect(result.current[0].loading).toBe(false)
    expect(result.current[0].data).toBe('data')
  })

  it('execute() carga datos correctamente', async () => {
    const asyncFn = vi.fn().mockResolvedValue({ items: [1, 2, 3] })
    const { result } = renderHook(() => useAsync(asyncFn))

    await act(async () => {
      await result.current[1].execute()
    })

    expect(result.current[0].data).toEqual({ items: [1, 2, 3] })
    expect(result.current[0].loading).toBe(false)
    expect(asyncFn).toHaveBeenCalledTimes(1)
  })

  it('maneja errores correctamente', async () => {
    const error = new Error('Test error')
    const asyncFn = vi.fn().mockRejectedValue(error)
    const { result } = renderHook(() => useAsync(asyncFn))

    await act(async () => {
      try {
        await result.current[1].execute()
      } catch (e) {
        // Expected
      }
    })

    expect(result.current[0].error).toBe(error)
    expect(result.current[0].loading).toBe(false)
  })

  it('llama onSuccess callback al completar', async () => {
    const onSuccess = vi.fn()
    const asyncFn = vi.fn().mockResolvedValue('success-data')
    const { result } = renderHook(() => useAsync(asyncFn, { onSuccess }))

    await act(async () => {
      await result.current[1].execute()
    })

    expect(onSuccess).toHaveBeenCalledWith('success-data')
  })

  it('llama onError callback al fallar', async () => {
    const onError = vi.fn()
    const error = new Error('Fail')
    const asyncFn = vi.fn().mockRejectedValue(error)
    const { result } = renderHook(() => useAsync(asyncFn, { onError }))

    await act(async () => {
      try {
        await result.current[1].execute()
      } catch (e) {
        // Expected
      }
    })

    expect(onError).toHaveBeenCalledWith(error)
  })

  it('reset() restaura el estado inicial', async () => {
    const asyncFn = vi.fn().mockResolvedValue('data')
    const { result } = renderHook(() => useAsync(asyncFn, { initialData: 'initial' }))

    await act(async () => {
      await result.current[1].execute()
    })

    expect(result.current[0].data).toBe('data')

    act(() => {
      result.current[1].reset()
    })

    expect(result.current[0].data).toBe('initial')
    expect(result.current[0].loading).toBe(false)
    expect(result.current[0].error).toBe(null)
  })

  it('setData() actualiza datos manualmente', () => {
    const asyncFn = vi.fn().mockResolvedValue('data')
    const { result } = renderHook(() => useAsync(asyncFn))

    act(() => {
      result.current[1].setData('manual-data')
    })

    expect(result.current[0].data).toBe('manual-data')
  })

  it('pasa argumentos a la función async', async () => {
    const asyncFn = vi.fn().mockResolvedValue('result')
    const { result } = renderHook(() => useAsync(asyncFn))

    await act(async () => {
      await result.current[1].execute('arg1', 'arg2')
    })

    expect(asyncFn).toHaveBeenCalledWith('arg1', 'arg2')
  })
})

describe('useDebounce', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('devuelve valor inicial inmediatamente', () => {
    const { result } = renderHook(() => useDebounce('initial', 300))
    expect(result.current).toBe('initial')
  })

  it('actualiza valor después del delay', async () => {
    const { result, rerender } = renderHook(
      ({ value }) => useDebounce(value, 300),
      { initialProps: { value: 'initial' } }
    )

    rerender({ value: 'updated' })
    expect(result.current).toBe('initial')

    act(() => {
      vi.advanceTimersByTime(300)
    })

    expect(result.current).toBe('updated')
  })

  it('cancela updates anteriores', async () => {
    const { result, rerender } = renderHook(
      ({ value }) => useDebounce(value, 300),
      { initialProps: { value: 'initial' } }
    )

    rerender({ value: 'first' })
    act(() => {
      vi.advanceTimersByTime(100)
    })

    rerender({ value: 'second' })
    act(() => {
      vi.advanceTimersByTime(100)
    })

    rerender({ value: 'third' })
    act(() => {
      vi.advanceTimersByTime(300)
    })

    expect(result.current).toBe('third')
  })
})

describe('useToggle', () => {
  it('inicia con valor por defecto false', () => {
    const { result } = renderHook(() => useToggle())
    expect(result.current[0]).toBe(false)
  })

  it('inicia con valor inicial provisto', () => {
    const { result } = renderHook(() => useToggle(true))
    expect(result.current[0]).toBe(true)
  })

  it('toggle() alterna el valor', () => {
    const { result } = renderHook(() => useToggle(false))

    act(() => {
      result.current[1]() // toggle
    })
    expect(result.current[0]).toBe(true)

    act(() => {
      result.current[1]() // toggle
    })
    expect(result.current[0]).toBe(false)
  })

  it('setTrue() setea a true', () => {
    const { result } = renderHook(() => useToggle(false))

    act(() => {
      result.current[2]() // setTrue
    })
    expect(result.current[0]).toBe(true)
  })

  it('setFalse() setea a false', () => {
    const { result } = renderHook(() => useToggle(true))

    act(() => {
      result.current[3]() // setFalse
    })
    expect(result.current[0]).toBe(false)
  })
})

describe('useLocalStorage', () => {
  const localStorageMock = {
    store: {},
    getItem: vi.fn((key) => localStorageMock.store[key] || null),
    setItem: vi.fn((key, value) => {
      localStorageMock.store[key] = value
    }),
    clear: vi.fn(() => {
      localStorageMock.store = {}
    })
  }

  beforeEach(() => {
    Object.defineProperty(window, 'localStorage', { value: localStorageMock })
    localStorageMock.clear()
    vi.clearAllMocks()
  })

  it('devuelve valor inicial si no hay valor en storage', () => {
    const { result } = renderHook(() => useLocalStorage('test-key', 'default'))
    expect(result.current[0]).toBe('default')
  })

  it('devuelve valor de storage si existe', () => {
    localStorageMock.store['test-key'] = JSON.stringify('stored-value')
    const { result } = renderHook(() => useLocalStorage('test-key', 'default'))
    expect(result.current[0]).toBe('stored-value')
  })

  it('guarda valor en storage al actualizar', () => {
    const { result } = renderHook(() => useLocalStorage('test-key', 'default'))

    act(() => {
      result.current[1]('new-value')
    })

    expect(result.current[0]).toBe('new-value')
    expect(localStorageMock.setItem).toHaveBeenCalledWith('test-key', JSON.stringify('new-value'))
  })

  it('acepta función como setter', () => {
    const { result } = renderHook(() => useLocalStorage('counter', 0))

    act(() => {
      result.current[1](prev => prev + 1)
    })

    expect(result.current[0]).toBe(1)
  })

  it('maneja objetos complejos', () => {
    const { result } = renderHook(() => useLocalStorage('user', { name: '' }))

    act(() => {
      result.current[1]({ name: 'Juan', age: 30 })
    })

    expect(result.current[0]).toEqual({ name: 'Juan', age: 30 })
  })
})

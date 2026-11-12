/**
 * `useRecorridos` avisa cuando la carga falla (#1549, B3).
 *
 * Un error del server, una excepción o el timeout de 8 s dejaban la lista en [] sin ninguna
 * señal: la pantalla lo mostraba como «No hay recorridos registrados para esta fecha».
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'

const { respuesta } = vi.hoisted(() => ({
  respuesta: { actual: null as unknown, stats: null as unknown },
}))

vi.mock('./base', () => {
  const cadena: Record<string, unknown> = {}
  for (const m of ['select', 'eq', 'neq', 'gte']) cadena[m] = () => cadena
  // La última llamada de la cadena es la que se espera: devuelve lo que fije el test.
  cadena.order = () => respuesta.actual
  cadena.lte = () => respuesta.stats
  return { supabase: { from: () => cadena } }
})

import { useRecorridos } from './useRecorridos'

const fila = {
  id: '7', transportista_id: 't1', fecha: '2026-11-12', estado: 'en_curso',
  recorrido_pedidos: [], transportista: { id: 't1', nombre: 'Rulo' },
}

describe('useRecorridos — error de carga (#1549)', () => {
  beforeEach(() => { respuesta.actual = null; respuesta.stats = null })
  afterEach(() => { vi.useRealTimers() })

  it('un error del server deja la lista vacía y lo marca como error', async () => {
    respuesta.actual = Promise.resolve({ data: null, error: { message: 'boom' } })
    const { result } = renderHook(() => useRecorridos())

    await act(async () => { await result.current.fetchRecorridosPorFecha('2026-11-12') })

    expect(result.current.recorridos).toEqual([])
    expect(result.current.error).toBe(true)
  })

  it('una excepción de red también', async () => {
    respuesta.actual = Promise.reject(new TypeError('Failed to fetch'))
    const { result } = renderHook(() => useRecorridos())

    await act(async () => { await result.current.fetchRecorridosPorFecha('2026-11-12') })

    expect(result.current.error).toBe(true)
  })

  it('un timeout (8 s) también', async () => {
    vi.useFakeTimers()
    respuesta.actual = new Promise(() => {}) // la query nunca vuelve
    const { result } = renderHook(() => useRecorridos())

    await act(async () => {
      const carga = result.current.fetchRecorridosPorFecha('2026-11-12')
      await vi.advanceTimersByTimeAsync(8000)
      await carga
    })

    expect(result.current.recorridos).toEqual([])
    expect(result.current.error).toBe(true)
  })

  it('una carga que sale bien no es error, y reintentar tras un error lo limpia', async () => {
    const { result } = renderHook(() => useRecorridos())

    respuesta.actual = Promise.resolve({ data: null, error: { message: 'boom' } })
    await act(async () => { await result.current.fetchRecorridosPorFecha('2026-11-12') })
    expect(result.current.error).toBe(true)

    respuesta.actual = Promise.resolve({ data: [fila], error: null })
    await act(async () => { await result.current.fetchRecorridosPorFecha('2026-11-12') })

    expect(result.current.error).toBe(false)
    expect(result.current.recorridos).toHaveLength(1)
  })

  it('un día sin recorridos (respuesta vacía) NO es error', async () => {
    respuesta.actual = Promise.resolve({ data: [], error: null })
    const { result } = renderHook(() => useRecorridos())

    await act(async () => { await result.current.fetchRecorridosPorFecha('2026-11-12') })

    expect(result.current.recorridos).toEqual([])
    expect(result.current.error).toBe(false)
  })

  it('si fallan las estadísticas, también lo marca (en vez de pasar por «0 recorridos»)', async () => {
    respuesta.stats = Promise.reject(new TypeError('Failed to fetch'))
    const { result } = renderHook(() => useRecorridos())

    let stats: { total: number } | undefined
    await act(async () => { stats = await result.current.getEstadisticasRecorridos('2026-11-01', '2026-11-12') })

    expect(stats?.total).toBe(0)
    expect(result.current.error).toBe(true)
  })

  it('estadísticas que salen bien (aunque sean 0) no marcan error', async () => {
    respuesta.stats = Promise.resolve({ data: [], error: null })
    const { result } = renderHook(() => useRecorridos())

    await act(async () => { await result.current.getEstadisticasRecorridos('2026-11-01', '2026-11-12') })

    expect(result.current.error).toBe(false)
  })
})

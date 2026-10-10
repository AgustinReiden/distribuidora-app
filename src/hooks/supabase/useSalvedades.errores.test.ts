/**
 * #1081 — `resolverSalvedad` mostraba en el toast el `error` crudo de supabase-js
 * ("TypeError: Failed to fetch") y después lanzaba el mensaje normalizado.
 * Misma regla que useRendiciones: el toast sale de `errorDeSupabase`.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'

const rpc = vi.fn()
const notifyError = vi.fn()

vi.mock('./base', () => ({
  supabase: { rpc: (...a: unknown[]) => rpc(...a) },
  notifyError: (...a: unknown[]) => notifyError(...a),
}))

import { useSalvedades } from './useSalvedades'

const INPUT = { salvedadId: '5', estadoResolucion: 'resuelta' } as never

describe('useSalvedades.resolverSalvedad — el toast no muestra el error crudo (#1081)', () => {
  beforeEach(() => {
    rpc.mockReset()
    notifyError.mockReset()
  })

  it('fallo de red: el toast dice "sin conexión", no "Failed to fetch", y coincide con el throw', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' } })
    const { result } = renderHook(() => useSalvedades())

    let lanzado: Error | undefined
    await act(async () => {
      await result.current.resolverSalvedad(INPUT).catch((e: Error) => { lanzado = e })
    })

    expect(lanzado!.message).toMatch(/Sin conexión/)
    expect(notifyError).toHaveBeenCalledTimes(1)
    const toast = String(notifyError.mock.calls[0][0])
    expect(toast).not.toMatch(/failed to fetch/i)
    expect(toast).toContain(lanzado!.message)
  })

  it('error del servidor: el toast conserva el prefijo y el mensaje del servidor', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'Salvedad ya resuelta', details: '', hint: '', code: 'P0001' } })
    const { result } = renderHook(() => useSalvedades())

    let lanzado: Error | undefined
    await act(async () => {
      await result.current.resolverSalvedad(INPUT).catch((e: Error) => { lanzado = e })
    })

    expect(lanzado!.message).toBe('Salvedad ya resuelta')
    expect(notifyError).toHaveBeenCalledWith('Error al resolver salvedad: Salvedad ya resuelta')
  })
})

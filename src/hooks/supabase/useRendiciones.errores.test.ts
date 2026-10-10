/**
 * #1081 — el toast de useRendiciones mostraba el `error` CRUDO de supabase-js
 * ("TypeError: Failed to fetch") y, justo después, el throw llevaba el mensaje
 * normalizado: la pantalla decía dos cosas distintas por el mismo fallo.
 *
 * supabase-js no lanza Error: devuelve un objeto plano. Sin servidor trae
 * `{ message: 'TypeError: Failed to fetch', code: '' }`; con servidor, el JSON de
 * PostgREST (`code: 'P0001'` de un RAISE). El toast tiene que usar lo que sale de
 * `errorDeSupabase`: "sin conexión" para lo primero, el mensaje del servidor
 * (con su prefijo) para lo segundo.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'

const rpc = vi.fn()
const notifyError = vi.fn()

vi.mock('./base', () => ({
  supabase: { rpc: (...a: unknown[]) => rpc(...a) },
  notifyError: (...a: unknown[]) => notifyError(...a),
}))

import { useRendiciones } from './useRendiciones'

const RED = { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' }
const SERVIDOR = { message: 'Solo admin puede controlar', details: '', hint: '', code: 'P0001' }

type Camino = {
  nombre: string
  prefijo: string
  llamar: (h: ReturnType<typeof useRendiciones>) => Promise<unknown>
}

const CAMINOS: Camino[] = [
  { nombre: 'marcarControlada', prefijo: 'Error al marcar como controlada: ', llamar: (h) => h.marcarControlada('2026-10-01', 't1') },
  { nombre: 'desmarcarControlada', prefijo: 'Error al desmarcar control: ', llamar: (h) => h.desmarcarControlada('2026-10-01', 't1') },
  { nombre: 'confirmarRendicion', prefijo: 'Error al cerrar rendición: ', llamar: (h) => h.confirmarRendicion('2026-10-01', 't1', 'confirmada') },
  { nombre: 'resolverRendicion', prefijo: 'Error al resolver rendición: ', llamar: (h) => h.resolverRendicion('2026-10-01', 't1', 'ok') },
  { nombre: 'consultarControl', prefijo: 'Error al consultar control: ', llamar: (h) => h.consultarControl('t1', '2026-10-01') },
]

describe('useRendiciones — el toast no muestra el error crudo de supabase (#1081)', () => {
  beforeEach(() => {
    rpc.mockReset()
    notifyError.mockReset()
  })

  describe.each(CAMINOS)('$nombre', ({ prefijo, llamar }) => {
    it('fallo de red: el toast dice "sin conexión", no "Failed to fetch", y coincide con el throw', async () => {
      rpc.mockResolvedValue({ data: null, error: RED })
      const { result } = renderHook(() => useRendiciones())

      let lanzado: Error | undefined
      await act(async () => {
        await llamar(result.current).catch((e: Error) => { lanzado = e })
      })

      expect(lanzado).toBeInstanceOf(Error)
      expect(lanzado!.message).toMatch(/Sin conexión/)
      expect(notifyError).toHaveBeenCalledTimes(1)
      const toast = String(notifyError.mock.calls[0][0])
      expect(toast).not.toMatch(/failed to fetch/i)
      expect(toast).toContain(lanzado!.message)
    })

    it('error del servidor: el toast conserva el prefijo y el mensaje del servidor', async () => {
      rpc.mockResolvedValue({ data: null, error: SERVIDOR })
      const { result } = renderHook(() => useRendiciones())

      let lanzado: Error | undefined
      await act(async () => {
        await llamar(result.current).catch((e: Error) => { lanzado = e })
      })

      expect(lanzado!.message).toBe('Solo admin puede controlar')
      expect(notifyError).toHaveBeenCalledWith(prefijo + 'Solo admin puede controlar')
    })
  })
})

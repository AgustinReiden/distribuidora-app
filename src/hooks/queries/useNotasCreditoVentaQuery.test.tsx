/**
 * Las dos escrituras de la NC de venta tienen plazo de red (#1440, #1366):
 *   - `crear_nota_credito_venta` es idempotente por `p_client_request_id`: la red
 *     se reintenta (3 intentos) y lo que contestó el servidor no.
 *   - `anular_nota_credito_venta` no tiene clave: plazo, un solo intento.
 *
 * Como en el resto de los tests de errores, el error es siempre la forma real de
 * supabase-js (un objeto plano), nunca un `new Error`.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { isTransientNetworkError } from '../../utils/retryWithBackoff'
import { PLAZO_ESCRITURA_MS } from '../../utils/escrituraIdempotente'

const h = vi.hoisted(() => ({
  rpc: vi.fn(),
  abortSignal: vi.fn(),
}))

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (...a: unknown[]) => {
      const promesa = Promise.resolve(h.rpc(...a))
      return Object.assign(promesa, { abortSignal: (signal: AbortSignal) => { h.abortSignal(signal); return promesa } })
    },
  },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import {
  useCrearNotaCreditoVentaMutation,
  useAnularNotaCreditoVentaMutation,
} from './useNotasCreditoVentaQuery'

const ERR_SERVIDOR = { message: 'La nota de crédito ya está anulada', details: '', hint: '', code: 'P0001' }
const ERR_RED = { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' }
const OK_CREAR = { data: { nota_credito_id: 1, pago_id: 2, total: 100, fecha: '2026-10-01' }, error: null }

const crearInput = {
  pedidoId: '9', clienteId: '5', items: [{ pedido_item_id: 1, cantidad: 1 }],
  motivo: 'producto_vencido' as const, clientRequestId: 'r1',
}
const anularInput = { notaCreditoId: '4', motivo: 'error de carga' }

function wrapper() {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  })
  return function W({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

function esServidor(e: unknown) {
  expect(e).toBeInstanceOf(Error)
  expect((e as Error).message).toBe(ERR_SERVIDOR.message)
  expect((e as { code?: string }).code).toBe('P0001')
}

function esRed(e: unknown, patron: RegExp) {
  expect(e).toBeInstanceOf(Error)
  expect((e as Error).message).not.toMatch(/failed to fetch/i)
  expect((e as Error).message).toMatch(/sin conexi/i)
  expect((e as Error).message).toMatch(patron)
  expect((e as Error).message).toMatch(/revisá la ficha del cliente antes de reintentar/i)
  expect(isTransientNetworkError(e)).toBe(true)
}

beforeEach(() => {
  h.rpc.mockReset()
  h.abortSignal.mockReset()
})

describe('crearNotaCreditoVenta (idempotente por client_request_id)', () => {
  it('servidor: un solo intento y el mensaje llega con su code', async () => {
    h.rpc.mockResolvedValue({ data: null, error: ERR_SERVIDOR })
    const { result } = renderHook(() => useCrearNotaCreditoVentaMutation(), { wrapper: wrapper() })
    await expect(result.current.mutateAsync(crearInput)).rejects.toSatisfy((e: unknown) => {
      esServidor(e)
      return true
    })
    expect(h.rpc).toHaveBeenCalledTimes(1)
  })

  it('le pasa un AbortSignal a supabase', async () => {
    h.rpc.mockResolvedValue(OK_CREAR)
    const { result } = renderHook(() => useCrearNotaCreditoVentaMutation(), { wrapper: wrapper() })
    await result.current.mutateAsync(crearInput)
    expect(h.abortSignal).toHaveBeenCalledWith(expect.any(AbortSignal))
  })

  it('red: se reintenta (3 intentos) y pide revisar la ficha antes de reintentar', async () => {
    h.rpc.mockResolvedValue({ data: null, error: ERR_RED })
    const { result } = renderHook(() => useCrearNotaCreditoVentaMutation(), { wrapper: wrapper() })
    await expect(result.current.mutateAsync(crearInput)).rejects.toSatisfy((e: unknown) => {
      esRed(e, /no se pudo confirmar la nota de crédito/i)
      return true
    })
    expect(h.rpc).toHaveBeenCalledTimes(3)
  }, 15000)

  it('un fallo de red transitorio se repite y termina bien', async () => {
    h.rpc
      .mockResolvedValueOnce({ data: null, error: ERR_RED })
      .mockResolvedValueOnce(OK_CREAR)
    const { result } = renderHook(() => useCrearNotaCreditoVentaMutation(), { wrapper: wrapper() })
    await expect(result.current.mutateAsync(crearInput)).resolves.toMatchObject({ nota_credito_id: 1 })
    expect(h.rpc).toHaveBeenCalledTimes(2)
  }, 15000)

  it('sin client_request_id: no se reintenta (un solo intento)', async () => {
    h.rpc.mockResolvedValue({ data: null, error: ERR_RED })
    const { result } = renderHook(() => useCrearNotaCreditoVentaMutation(), { wrapper: wrapper() })
    await expect(result.current.mutateAsync({ ...crearInput, clientRequestId: '' })).rejects.toBeInstanceOf(Error)
    expect(h.rpc).toHaveBeenCalledTimes(1)
  })

  describe('colgada (plazo de red)', () => {
    beforeEach(() => { vi.useFakeTimers() })
    afterEach(() => { vi.useRealTimers() })

    it('corta a los 20 s, un solo intento, y pide revisar la ficha antes de reintentar', async () => {
      h.rpc.mockReturnValue(new Promise(() => {}))
      const { result } = renderHook(() => useCrearNotaCreditoVentaMutation(), { wrapper: wrapper() })
      const promesa = result.current.mutateAsync(crearInput).catch((e: unknown) => e)
      await vi.advanceTimersByTimeAsync(PLAZO_ESCRITURA_MS)
      const e = await promesa
      esRed(e, /no se pudo confirmar la nota de crédito/i)
      expect((e as Error).message).not.toMatch(/sin respuesta del servidor/i)
      expect(h.rpc).toHaveBeenCalledTimes(1)
    })
  })
})

describe('anularNotaCreditoVenta (sin clave de idempotencia: plazo, un solo intento)', () => {
  it('servidor: un solo intento y el mensaje llega con su code', async () => {
    h.rpc.mockResolvedValue({ data: null, error: ERR_SERVIDOR })
    const { result } = renderHook(() => useAnularNotaCreditoVentaMutation(), { wrapper: wrapper() })
    await expect(result.current.mutateAsync(anularInput)).rejects.toSatisfy((e: unknown) => {
      esServidor(e)
      return true
    })
    expect(h.rpc).toHaveBeenCalledTimes(1)
  })

  it('le pasa un AbortSignal a supabase', async () => {
    h.rpc.mockResolvedValue({ data: null, error: null })
    const { result } = renderHook(() => useAnularNotaCreditoVentaMutation(), { wrapper: wrapper() })
    await result.current.mutateAsync(anularInput)
    expect(h.abortSignal).toHaveBeenCalledWith(expect.any(AbortSignal))
  })

  it('red: NO se reintenta (1 intento) y pide revisar la ficha antes de reintentar', async () => {
    h.rpc.mockResolvedValue({ data: null, error: ERR_RED })
    const { result } = renderHook(() => useAnularNotaCreditoVentaMutation(), { wrapper: wrapper() })
    await expect(result.current.mutateAsync(anularInput)).rejects.toSatisfy((e: unknown) => {
      esRed(e, /no se pudo confirmar la anulación/i)
      return true
    })
    expect(h.rpc).toHaveBeenCalledTimes(1)
  })

  describe('colgada (plazo de red)', () => {
    beforeEach(() => { vi.useFakeTimers() })
    afterEach(() => { vi.useRealTimers() })

    it('corta a los 20 s, un solo intento, y pide revisar la ficha antes de reintentar', async () => {
      h.rpc.mockReturnValue(new Promise(() => {}))
      const { result } = renderHook(() => useAnularNotaCreditoVentaMutation(), { wrapper: wrapper() })
      const promesa = result.current.mutateAsync(anularInput).catch((e: unknown) => e)
      await vi.advanceTimersByTimeAsync(PLAZO_ESCRITURA_MS)
      const e = await promesa
      esRed(e, /no se pudo confirmar la anulación/i)
      expect((e as Error).message).not.toMatch(/sin respuesta del servidor/i)
      expect(h.rpc).toHaveBeenCalledTimes(1)
    })
  })
})

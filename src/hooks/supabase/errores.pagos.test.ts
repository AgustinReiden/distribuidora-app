/**
 * #760 — los hooks de pagos y reportes financieros tiran un Error de verdad.
 *
 * supabase-js NO lanza Error: devuelve un objeto plano. Estos tests usan SIEMPRE
 * esa forma real (nunca `new Error`):
 *   - respondió el servidor → `{ message, details, hint, code: 'P0001' }`
 *   - sin red               → `{ message: 'TypeError: Failed to fetch', code: '' }`
 *
 * Y fijan lo que no puede romperse: el reintento de los pagos idempotentes sigue
 * reintentando red (3 llamadas) y NO reintenta lo que contestó el servidor (1).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { usePagos } from './usePagos'
import { useReportesFinancieros } from './useReportesFinancieros'
import { isTransientNetworkError } from '../../utils/retryWithBackoff'

const mockSelect = vi.fn()
const mockInsert = vi.fn()
const mockDelete = vi.fn()
const mockEq = vi.fn()
const mockOrder = vi.fn()
const mockSingle = vi.fn()
const mockRpc = vi.fn()

vi.mock('./base', () => ({
  supabase: {
    from: vi.fn(() => ({
      select: mockSelect,
      insert: mockInsert,
      delete: mockDelete,
      eq: mockEq,
      order: mockOrder,
      single: mockSingle,
    })),
    rpc: (...a: unknown[]) => mockRpc(...a),
  },
  notifyError: vi.fn(),
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { notifyError } from './base'

const ERR_SERVIDOR = {
  message: 'Solo admin o encargado puede registrar pagos',
  details: 'detalle',
  hint: 'pista',
  code: 'P0001',
}
const ERR_RED = { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' }
const REQ = '11111111-2222-4333-8444-555555555555'

async function capturar(fn: () => Promise<unknown>): Promise<unknown> {
  let capturado: unknown
  await act(async () => {
    try {
      await fn()
    } catch (e) {
      capturado = e
    }
  })
  return capturado
}

function esServidor(e: unknown) {
  expect(e).toBeInstanceOf(Error)
  expect((e as Error).message).toBe(ERR_SERVIDOR.message)
  expect((e as { code?: string }).code).toBe('P0001')
}

function esRed(e: unknown) {
  expect(e).toBeInstanceOf(Error)
  expect((e as Error).message).not.toMatch(/failed to fetch/i)
  expect((e as Error).message).toMatch(/sin conexi/i)
  expect(isTransientNetworkError(e)).toBe(true)
}

function ultimoAviso(): string {
  const calls = (notifyError as unknown as ReturnType<typeof vi.fn>).mock.calls
  return calls[0][0] as string
}

describe('usePagos — errores de supabase', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockSelect.mockReturnThis()
    mockInsert.mockReturnThis()
    mockDelete.mockReturnThis()
    mockEq.mockReturnThis()
    mockOrder.mockReturnThis()
  })

  describe('registrarPago (idempotente: reintenta red, no servidor)', () => {
    it('servidor: un solo intento y el mensaje llega', async () => {
      mockSingle.mockResolvedValue({ data: null, error: ERR_SERVIDOR })
      const { result } = renderHook(() => usePagos())
      const e = await capturar(() =>
        result.current.registrarPago({ clienteId: 'c1', monto: 100, clientRequestId: REQ }))
      esServidor(e)
      expect(mockSingle).toHaveBeenCalledTimes(1)
    })

    it('red: se reintenta (3 intentos) y el mensaje pide confirmar antes de reintentar', async () => {
      mockSingle.mockResolvedValue({ data: null, error: ERR_RED })
      const { result } = renderHook(() => usePagos())
      const e = await capturar(() =>
        result.current.registrarPago({ clienteId: 'c1', monto: 100, clientRequestId: REQ }))
      esRed(e)
      expect((e as Error).message).toMatch(/no se pudo confirmar/i)
      expect(mockSingle).toHaveBeenCalledTimes(1 + 2)
    }, 15000)

    it('23505 con request id: un solo intento, no se reintenta', async () => {
      mockSingle.mockResolvedValue({
        data: null,
        error: { message: 'duplicate key', details: '', hint: '', code: '23505' },
      })
      const { result } = renderHook(() => usePagos())
      const e = await capturar(() =>
        result.current.registrarPago({ clienteId: 'c1', monto: 100, clientRequestId: REQ }))
      expect(e).toBeInstanceOf(Error)
      expect(mockSingle).toHaveBeenCalledTimes(1)
    })
  })

  describe('registrarPagosBatch', () => {
    const input = {
      clienteId: 'c1', pedidoId: 'p1', fecha: '2026-10-01',
      pagos: [{ monto: 100, formaPago: 'efectivo' }], clientRequestIds: [REQ],
    }
    it('servidor: un solo intento y el mensaje llega', async () => {
      mockSelect.mockResolvedValue({ data: null, error: ERR_SERVIDOR })
      const { result } = renderHook(() => usePagos())
      const e = await capturar(() => result.current.registrarPagosBatch(input as never))
      esServidor(e)
      expect(mockSelect).toHaveBeenCalledTimes(1)
    })
    it('red: se reintenta y avisa que no se pudo confirmar', async () => {
      mockSelect.mockResolvedValue({ data: null, error: ERR_RED })
      const { result } = renderHook(() => usePagos())
      const e = await capturar(() => result.current.registrarPagosBatch(input as never))
      esRed(e)
      expect((e as Error).message).toMatch(/no se pudo confirmar/i)
      expect(mockSelect).toHaveBeenCalledTimes(3)
    }, 15000)
  })

  describe('registrarPagoFIFO', () => {
    const input = { clienteId: 'c1', monto: 100, formaPago: 'efectivo', clientRequestId: REQ }
    it('servidor: un solo intento y el mensaje llega', async () => {
      mockRpc.mockResolvedValue({ data: null, error: ERR_SERVIDOR })
      const { result } = renderHook(() => usePagos())
      const e = await capturar(() => result.current.registrarPagoFIFO(input as never))
      esServidor(e)
      expect(mockRpc).toHaveBeenCalledTimes(1)
    })
    it('red: se reintenta y avisa que no se pudo confirmar', async () => {
      mockRpc.mockResolvedValue({ data: null, error: ERR_RED })
      const { result } = renderHook(() => usePagos())
      const e = await capturar(() => result.current.registrarPagoFIFO(input as never))
      esRed(e)
      expect((e as Error).message).toMatch(/no se pudo confirmar/i)
      expect(mockRpc).toHaveBeenCalledTimes(3)
    }, 15000)
  })

  describe('registrarPagoCombinadoFIFO', () => {
    const input = {
      clienteId: 'c1', metodos: [{ monto: 100, formaPago: 'efectivo' }], clientRequestId: REQ,
    }
    it('servidor: un solo intento y el mensaje llega', async () => {
      mockRpc.mockResolvedValue({ data: null, error: ERR_SERVIDOR })
      const { result } = renderHook(() => usePagos())
      const e = await capturar(() => result.current.registrarPagoCombinadoFIFO(input as never))
      esServidor(e)
      expect(mockRpc).toHaveBeenCalledTimes(1)
    })
    it('red: se reintenta y avisa que no se pudo confirmar', async () => {
      mockRpc.mockResolvedValue({ data: null, error: ERR_RED })
      const { result } = renderHook(() => usePagos())
      const e = await capturar(() => result.current.registrarPagoCombinadoFIFO(input as never))
      esRed(e)
      expect((e as Error).message).toMatch(/no se pudo confirmar/i)
      expect(mockRpc).toHaveBeenCalledTimes(3)
    }, 15000)
  })

  describe('eliminarPago', () => {
    it('servidor', async () => {
      mockEq.mockResolvedValue({ error: ERR_SERVIDOR })
      const { result } = renderHook(() => usePagos())
      esServidor(await capturar(() => result.current.eliminarPago('9')))
    })
    it('red', async () => {
      mockEq.mockResolvedValue({ error: ERR_RED })
      const { result } = renderHook(() => usePagos())
      const e = await capturar(() => result.current.eliminarPago('9'))
      esRed(e)
      expect((e as Error).message).toMatch(/no se pudo confirmar/i)
    })
  })

  describe('actualizarFormaPagoDePago', () => {
    it('servidor', async () => {
      mockRpc.mockResolvedValue({ error: ERR_SERVIDOR })
      const { result } = renderHook(() => usePagos())
      esServidor(await capturar(() => result.current.actualizarFormaPagoDePago('9', 'transferencia')))
    })
    it('red', async () => {
      mockRpc.mockResolvedValue({ error: ERR_RED })
      const { result } = renderHook(() => usePagos())
      const e = await capturar(() => result.current.actualizarFormaPagoDePago('9', 'transferencia'))
      esRed(e)
      expect((e as Error).message).toMatch(/no se pudo confirmar/i)
    })
  })

  describe('fetchPagosPedido (lectura: lo notifica y devuelve [])', () => {
    it('servidor: el toast lleva el mensaje del servidor', async () => {
      mockOrder.mockResolvedValue({ data: null, error: ERR_SERVIDOR })
      const { result } = renderHook(() => usePagos())
      await act(async () => { await result.current.fetchPagosPedido('p1') })
      expect(ultimoAviso()).toContain(ERR_SERVIDOR.message)
    })
    it('red: el toast no dice Failed to fetch', async () => {
      mockOrder.mockResolvedValue({ data: null, error: ERR_RED })
      const { result } = renderHook(() => usePagos())
      await act(async () => { await result.current.fetchPagosPedido('p1') })
      expect(ultimoAviso()).not.toMatch(/failed to fetch/i)
      expect(ultimoAviso()).toMatch(/no se pudo cargar/i)
    })
  })
})

describe('useReportesFinancieros — errores de supabase', () => {
  beforeEach(() => vi.clearAllMocks())

  it('cuentas por cobrar, servidor: el aviso lleva el mensaje del servidor', async () => {
    mockRpc.mockResolvedValue({ data: null, error: ERR_SERVIDOR })
    const { result } = renderHook(() => useReportesFinancieros())
    await act(async () => { await result.current.generarReporteCuentasPorCobrar() })
    expect(ultimoAviso()).toContain(ERR_SERVIDOR.message)
  })

  it('cuentas por cobrar, red: no dice Failed to fetch', async () => {
    mockRpc.mockResolvedValue({ data: null, error: ERR_RED })
    const { result } = renderHook(() => useReportesFinancieros())
    await act(async () => { await result.current.generarReporteCuentasPorCobrar() })
    expect(ultimoAviso()).not.toMatch(/failed to fetch/i)
    expect(ultimoAviso()).toMatch(/no se pudo cargar/i)
  })

  it('rentabilidad, servidor', async () => {
    mockRpc.mockResolvedValue({ data: null, error: ERR_SERVIDOR })
    const { result } = renderHook(() => useReportesFinancieros())
    await act(async () => { await result.current.generarReporteRentabilidad('2026-10-01', '2026-10-31') })
    expect(ultimoAviso()).toContain(ERR_SERVIDOR.message)
  })

  it('rentabilidad, red', async () => {
    mockRpc.mockResolvedValue({ data: null, error: ERR_RED })
    const { result } = renderHook(() => useReportesFinancieros())
    await act(async () => { await result.current.generarReporteRentabilidad('2026-10-01', '2026-10-31') })
    expect(ultimoAviso()).not.toMatch(/failed to fetch/i)
    expect(ultimoAviso()).toMatch(/no se pudo cargar/i)
  })
})

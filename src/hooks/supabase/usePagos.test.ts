/**
 * Tests para usePagos hook
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { usePagos } from './usePagos'

// Mock de Supabase
const mockSelect = vi.fn().mockReturnThis()
const mockInsert = vi.fn().mockReturnThis()
const mockDelete = vi.fn().mockReturnThis()
const mockEq = vi.fn().mockReturnThis()
const mockOrder = vi.fn().mockReturnThis()
const mockSingle = vi.fn()
const mockIn = vi.fn()

vi.mock('./base', () => ({
  supabase: {
    from: vi.fn(() => ({
      select: mockSelect,
      insert: mockInsert,
      delete: mockDelete,
      eq: mockEq,
      order: mockOrder,
      single: mockSingle,
      in: mockIn
    })),
    rpc: vi.fn()
  },
  notifyError: vi.fn()
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 })
}))

import { supabase, notifyError } from './base'

describe('usePagos', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    // Reset chain returns
    mockSelect.mockReturnThis()
    mockInsert.mockReturnThis()
    mockDelete.mockReturnThis()
    mockEq.mockReturnThis()
    mockOrder.mockReturnThis()
  })

  describe('fetchPagosCliente', () => {
    it('debe cargar pagos de un cliente', async () => {
      const mockPagos = [
        { id: '1', cliente_id: 'c1', monto: 1000, usuario: { id: 'u1', nombre: 'Admin' } },
        { id: '2', cliente_id: 'c1', monto: 500, usuario: { id: 'u1', nombre: 'Admin' } }
      ]
      mockOrder.mockResolvedValueOnce({ data: mockPagos, error: null })

      const { result } = renderHook(() => usePagos())

      let pagos: unknown[]
      await act(async () => {
        pagos = await result.current.fetchPagosCliente('c1')
      })

      expect(supabase.from).toHaveBeenCalledWith('pagos')
      expect(mockSelect).toHaveBeenCalledWith('*, usuario:perfiles(id, nombre)')
      expect(mockEq).toHaveBeenCalledWith('cliente_id', 'c1')
      expect(pagos!).toHaveLength(2)
      expect(result.current.pagos).toHaveLength(2)
      expect(result.current.loading).toBe(false)
    })

    it('debe manejar errores en fetchPagosCliente', async () => {
      mockOrder.mockResolvedValueOnce({ data: null, error: new Error('DB error') })

      const { result } = renderHook(() => usePagos())

      let pagos: unknown[]
      await act(async () => {
        pagos = await result.current.fetchPagosCliente('c1')
      })

      expect(pagos!).toEqual([])
      expect(notifyError).toHaveBeenCalledWith(expect.stringContaining('Error al cargar pagos'))
    })
  })

  describe('registrarPago', () => {
    it('debe registrar un pago correctamente', async () => {
      const mockPago = { id: '1', cliente_id: 'c1', monto: 1500, forma_pago: 'efectivo' }
      mockSingle.mockResolvedValueOnce({ data: mockPago, error: null })

      const { result } = renderHook(() => usePagos())

      let pago: unknown
      await act(async () => {
        pago = await result.current.registrarPago({
          clienteId: 'c1',
          monto: 1500,
          formaPago: 'efectivo'
        })
      })

      expect(supabase.from).toHaveBeenCalledWith('pagos')
      expect(mockInsert).toHaveBeenCalledWith([expect.objectContaining({
        cliente_id: 'c1',
        monto: 1500,
        forma_pago: 'efectivo'
      })])
      expect(pago).toEqual(mockPago)
      expect(result.current.pagos).toContainEqual(mockPago)
    })

    it('debe lanzar error si falla el registro', async () => {
      mockSingle.mockResolvedValueOnce({ data: null, error: new Error('Insert failed') })

      const { result } = renderHook(() => usePagos())

      await expect(act(async () => {
        await result.current.registrarPago({ clienteId: 'c1', monto: 100 })
      })).rejects.toThrow()

      expect(notifyError).toHaveBeenCalledWith(expect.stringContaining('Error al registrar pago'))
    })
  })

  // Idempotencia (mig 167). El caso testigo es el pedido 3602: el mismo pago de
  // $111.280 entro 3 veces en 17 segundos porque el reintento del usuario no
  // tenia forma de identificarse como reintento.
  describe('registrarPago — idempotencia', () => {
    const REQUEST_ID = '11111111-2222-4333-8444-555555555555'

    it('manda client_request_id en el INSERT cuando el caller lo provee', async () => {
      mockSingle.mockResolvedValueOnce({ data: { id: '1', monto: 111280 }, error: null })

      const { result } = renderHook(() => usePagos())
      await act(async () => {
        await result.current.registrarPago({
          clienteId: 'c1', monto: 111280, formaPago: 'efectivo', clientRequestId: REQUEST_ID,
        })
      })

      expect(mockInsert).toHaveBeenCalledWith([expect.objectContaining({
        client_request_id: REQUEST_ID,
      })])
    })

    it('no manda la columna si el caller no pasa UUID (comportamiento historico)', async () => {
      mockSingle.mockResolvedValueOnce({ data: { id: '1', monto: 100 }, error: null })

      const { result } = renderHook(() => usePagos())
      await act(async () => {
        await result.current.registrarPago({ clienteId: 'c1', monto: 100 })
      })

      expect(mockInsert).toHaveBeenCalledWith([
        expect.not.objectContaining({ client_request_id: expect.anything() }),
      ])
    })

    it('ante 23505 devuelve la fila que ya existe en vez de duplicar el pago', async () => {
      const yaRegistrado = { id: '3280', cliente_id: 'c1', monto: 111280, forma_pago: 'efectivo' }
      mockSingle.mockResolvedValueOnce({
        data: null,
        error: { code: '23505', message: 'duplicate key value violates unique constraint "idx_pagos_client_request_id"' },
      })
      mockIn.mockResolvedValueOnce({ data: [yaRegistrado], error: null })

      const { result } = renderHook(() => usePagos())
      let pago: unknown
      await act(async () => {
        pago = await result.current.registrarPago({
          clienteId: 'c1', monto: 111280, formaPago: 'efectivo', clientRequestId: REQUEST_ID,
        })
      })

      expect(mockIn).toHaveBeenCalledWith('client_request_id', [REQUEST_ID])
      expect(pago).toEqual(yaRegistrado)
      expect(result.current.pagos).toContainEqual(yaRegistrado)
      expect(notifyError).not.toHaveBeenCalled()
    })

    it('ante 23505 sin poder releer la fila avisa que ya estaba registrado', async () => {
      mockSingle.mockResolvedValueOnce({ data: null, error: { code: '23505', message: 'duplicate key' } })
      mockIn.mockResolvedValueOnce({ data: [], error: null })

      const { result } = renderHook(() => usePagos())
      await expect(act(async () => {
        await result.current.registrarPago({
          clienteId: 'c1', monto: 100, clientRequestId: REQUEST_ID,
        })
      })).rejects.toThrow(/ya se había registrado/i)
    })
  })

  describe('registrarPagosBatch — idempotencia', () => {
    it('aparea cada UUID con su linea aunque haya lineas en cero filtradas', async () => {
      mockSelect.mockResolvedValueOnce({ data: [{ id: '1', monto: 500 }], error: null })

      const { result } = renderHook(() => usePagos())
      await act(async () => {
        await result.current.registrarPagosBatch({
          clienteId: 'c1',
          pedidoId: 'p1',
          fecha: '2026-08-05',
          pagos: [
            { formaPago: 'efectivo', monto: 0 },      // se filtra
            { formaPago: 'transferencia', monto: 500 },
          ],
          clientRequestIds: ['uuid-linea-0', 'uuid-linea-1'],
        })
      })

      // La linea que sobrevive es la #1: tiene que llevar SU uuid, no el de la #0.
      expect(mockInsert).toHaveBeenCalledWith([expect.objectContaining({
        monto: 500,
        forma_pago: 'transferencia',
        client_request_id: 'uuid-linea-1',
      })])
    })

    it('ante 23505 devuelve las filas del intento anterior', async () => {
      const previos = [{ id: '10', monto: 300 }, { id: '11', monto: 200 }]
      mockSelect.mockResolvedValueOnce({ data: null, error: { code: '23505', message: 'duplicate key' } })
      mockIn.mockResolvedValueOnce({ data: previos, error: null })

      const { result } = renderHook(() => usePagos())
      let pagos: unknown
      await act(async () => {
        pagos = await result.current.registrarPagosBatch({
          clienteId: 'c1',
          pedidoId: 'p1',
          fecha: '2026-08-05',
          pagos: [
            { formaPago: 'efectivo', monto: 300 },
            { formaPago: 'transferencia', monto: 200 },
          ],
          clientRequestIds: ['uuid-a', 'uuid-b'],
        })
      })

      expect(mockIn).toHaveBeenCalledWith('client_request_id', ['uuid-a', 'uuid-b'])
      expect(pagos).toEqual(previos)
    })
  })

  describe('registrarPagoFIFO — idempotencia', () => {
    it('manda p_client_request_id y expone idempotent_replay', async () => {
      ;(supabase.rpc as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
        data: {
          pago_ids: [3280], sobrante: 0, monto_total: 111280,
          aplicaciones: [], credito_aplicado: 0, idempotent_replay: true,
        },
        error: null,
      })

      const { result } = renderHook(() => usePagos())
      let res: { idempotentReplay?: boolean } | undefined
      await act(async () => {
        res = await result.current.registrarPagoFIFO({
          clienteId: 'c1', monto: 111280, formaPago: 'efectivo',
          clientRequestId: 'uuid-fifo',
        })
      })

      expect(supabase.rpc).toHaveBeenCalledWith(
        'registrar_pago_cliente_fifo',
        expect.objectContaining({ p_client_request_id: 'uuid-fifo' }),
      )
      expect(res!.idempotentReplay).toBe(true)
    })
  })

  describe('eliminarPago', () => {
    it('debe eliminar un pago y actualizar estado local', async () => {
      // First load pagos
      const mockPagos = [
        { id: '1', monto: 1000 },
        { id: '2', monto: 500 }
      ]
      mockOrder.mockResolvedValueOnce({ data: mockPagos, error: null })

      const { result } = renderHook(() => usePagos())

      await act(async () => {
        await result.current.fetchPagosCliente('c1')
      })

      // Now delete one
      mockEq.mockResolvedValueOnce({ error: null })

      await act(async () => {
        await result.current.eliminarPago('1')
      })

      expect(result.current.pagos).toHaveLength(1)
      expect(result.current.pagos[0].id).toBe('2')
    })

    it('debe lanzar error si falla la eliminación', async () => {
      mockEq.mockResolvedValueOnce({ error: new Error('Delete failed') })

      const { result } = renderHook(() => usePagos())

      await expect(act(async () => {
        await result.current.eliminarPago('1')
      })).rejects.toThrow()

      expect(notifyError).toHaveBeenCalledWith(expect.stringContaining('Error al eliminar pago'))
    })
  })

  describe('obtenerResumenCuenta', () => {
    it('debe obtener resumen via RPC', async () => {
      const mockResumen = { saldo_actual: 5000, total_pedidos: 10 }
      ;(supabase.rpc as ReturnType<typeof vi.fn>).mockResolvedValueOnce({ data: mockResumen, error: null })

      const { result } = renderHook(() => usePagos())

      let resumen: unknown
      await act(async () => {
        resumen = await result.current.obtenerResumenCuenta('c1')
      })

      expect(supabase.rpc).toHaveBeenCalledWith('obtener_resumen_cuenta_cliente', { p_cliente_id: 'c1' })
      expect(resumen).toEqual(mockResumen)
    })

    it('debe intentar fallback si RPC falla y retornar null si fallback tambien falla', async () => {
      // RPC fails, fallback queries also fail → returns null
      ;(supabase.rpc as ReturnType<typeof vi.fn>).mockResolvedValueOnce({ data: null, error: new Error('RPC not found') })
      // Fallback chain calls will fail because the shared mock returns mockReturnThis for all chained calls
      // which eventually doesn't resolve to { data }. This exercises the outer catch block.

      const { result } = renderHook(() => usePagos())

      let resumen: unknown
      await act(async () => {
        resumen = await result.current.obtenerResumenCuenta('c1')
      })

      // When both RPC and fallback fail, obtenerResumenCuenta catches and returns null
      expect(supabase.rpc).toHaveBeenCalledWith('obtener_resumen_cuenta_cliente', { p_cliente_id: 'c1' })
      expect(resumen).toBeNull()
    })

    it('debe retornar null si todo falla', async () => {
      ;(supabase.rpc as ReturnType<typeof vi.fn>).mockRejectedValueOnce(new Error('Fatal'))

      const { result } = renderHook(() => usePagos())

      let resumen: unknown
      await act(async () => {
        resumen = await result.current.obtenerResumenCuenta('c1')
      })

      expect(resumen).toBeNull()
    })
  })
})

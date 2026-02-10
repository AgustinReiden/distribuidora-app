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

vi.mock('./base', () => ({
  supabase: {
    from: vi.fn(() => ({
      select: mockSelect,
      insert: mockInsert,
      delete: mockDelete,
      eq: mockEq,
      order: mockOrder,
      single: mockSingle
    })),
    rpc: vi.fn()
  },
  notifyError: vi.fn()
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

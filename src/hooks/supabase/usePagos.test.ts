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
// `fetchPagosCliente` se pagina, asi que su cadena termina en `.range()`: es
// esa la que resuelve a `{ data, error }`, no `.order()`.
const mockRange = vi.fn()
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
      range: mockRange,
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
    // Por defecto: una pagina vacia, que corta el paginado en la primera vuelta.
    mockRange.mockResolvedValue({ data: [], error: null })
  })

  describe('fetchPagosCliente', () => {
    it('debe cargar pagos de un cliente', async () => {
      const mockPagos = [
        { id: '1', cliente_id: 'c1', monto: 1000, usuario: { id: 'u1', nombre: 'Admin' } },
        { id: '2', cliente_id: 'c1', monto: 500, usuario: { id: 'u1', nombre: 'Admin' } }
      ]
      mockRange.mockResolvedValueOnce({ data: mockPagos, error: null })

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
      mockRange.mockResolvedValueOnce({ data: null, error: { message: 'DB error' } })

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
    const rpcMock = () => supabase.rpc as ReturnType<typeof vi.fn>

    it('debe registrar un pago correctamente', async () => {
      const mockPago = { id: '1', cliente_id: 'c1', pedido_id: 'p1', monto: 1500, forma_pago: 'efectivo' }
      rpcMock().mockResolvedValueOnce({
        data: { success: true, pedido_id: 'p1', monto_total: 1500, pago_ids: [1], pagos: [mockPago] },
        error: null,
      })

      const { result } = renderHook(() => usePagos())

      let pago: unknown
      await act(async () => {
        pago = await result.current.registrarPago({
          clienteId: 'c1',
          pedidoId: 'p1',
          monto: 1500,
          formaPago: 'efectivo'
        })
      })

      expect(supabase.rpc).toHaveBeenCalledWith('registrar_pagos_pedido', expect.objectContaining({
        p_pedido_id: 'p1',
        p_metodos: [{ monto: 1500, forma_pago: 'efectivo' }],
        p_fecha: expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/),
        p_client_request_id: null,
      }))
      // `pagos` ya no tiene INSERT REST.
      expect(mockInsert).not.toHaveBeenCalled()
      expect(pago).toEqual(mockPago)
      expect(result.current.pagos).toContainEqual(mockPago)
    })

    // El contrato es propagar SIN notificar: notifica quien tiene contexto. Con
    // el `notifyError` que estaba acá, el alta de pedido mostraba dos toasts a
    // la vez y el generico le tapaba al bueno —el que avisa que el pedido SI se
    // creo y no hay que recargarlo—. Si alguien vuelve a agregar el notify, este
    // test tiene que ponerse en rojo.
    it('debe lanzar error si falla el registro, sin notificar', async () => {
      rpcMock().mockResolvedValueOnce({ data: null, error: new Error('Insert failed') })

      const { result } = renderHook(() => usePagos())

      await expect(act(async () => {
        await result.current.registrarPago({ clienteId: 'c1', pedidoId: 'p1', monto: 100 })
      })).rejects.toThrow()

      expect(notifyError).not.toHaveBeenCalled()
    })

    it('sin pedidoId rechaza (es un pago a cuenta) sin llamar a la RPC', async () => {
      const { result } = renderHook(() => usePagos())

      await expect(act(async () => {
        await result.current.registrarPago({ clienteId: 'c1', pedidoId: null, monto: 100 } as never)
      })).rejects.toThrow(/pago a cuenta/i)

      expect(supabase.rpc).not.toHaveBeenCalled()
      expect(notifyError).not.toHaveBeenCalled()
    })
  })

  // Idempotencia (mig 167). El caso testigo es el pedido 3602: el mismo pago de
  // $111.280 entro 3 veces en 17 segundos porque el reintento del usuario no
  // tenia forma de identificarse como reintento.
  describe('registrarPago — idempotencia', () => {
    const REQUEST_ID = '11111111-2222-4333-8444-555555555555'
    const rpcMock = () => supabase.rpc as ReturnType<typeof vi.fn>

    it('manda p_client_request_id a la RPC cuando el caller lo provee', async () => {
      rpcMock().mockResolvedValueOnce({
        data: { success: true, pagos: [{ id: '1', monto: 111280 }] }, error: null,
      })

      const { result } = renderHook(() => usePagos())
      await act(async () => {
        await result.current.registrarPago({
          clienteId: 'c1', pedidoId: 'p1', monto: 111280, formaPago: 'efectivo', clientRequestId: REQUEST_ID,
        })
      })

      expect(supabase.rpc).toHaveBeenCalledWith('registrar_pagos_pedido', expect.objectContaining({
        p_client_request_id: REQUEST_ID,
      }))
    })

    it('manda p_client_request_id null si el caller no pasa UUID (comportamiento historico)', async () => {
      rpcMock().mockResolvedValueOnce({
        data: { success: true, pagos: [{ id: '1', monto: 100 }] }, error: null,
      })

      const { result } = renderHook(() => usePagos())
      await act(async () => {
        await result.current.registrarPago({ clienteId: 'c1', pedidoId: 'p1', monto: 100 })
      })

      expect(supabase.rpc).toHaveBeenCalledWith('registrar_pagos_pedido', expect.objectContaining({
        p_client_request_id: null,
      }))
    })

    it('ante un replay idempotente devuelve las filas del cobro original', async () => {
      const yaRegistrado = { id: '3280', cliente_id: 'c1', monto: 111280, forma_pago: 'efectivo' }
      rpcMock().mockResolvedValueOnce({
        data: { success: true, idempotent_replay: true, pago_ids: [3280], pagos: [yaRegistrado] },
        error: null,
      })

      const { result } = renderHook(() => usePagos())
      let pago: unknown
      await act(async () => {
        pago = await result.current.registrarPago({
          clienteId: 'c1', pedidoId: 'p1', monto: 111280, formaPago: 'efectivo', clientRequestId: REQUEST_ID,
        })
      })

      expect(pago).toEqual(yaRegistrado)
      expect(result.current.pagos).toContainEqual(yaRegistrado)
      expect(notifyError).not.toHaveBeenCalled()
    })

    it('si la RPC no devuelve filas avisa que no se pudo confirmar', async () => {
      rpcMock().mockResolvedValueOnce({ data: { success: true, pagos: [] }, error: null })

      const { result } = renderHook(() => usePagos())
      await expect(act(async () => {
        await result.current.registrarPago({
          clienteId: 'c1', pedidoId: 'p1', monto: 100, clientRequestId: REQUEST_ID,
        })
      })).rejects.toThrow(/no se pudo confirmar/i)
    })
  })

  describe('registrarPagosBatch', () => {
    const rpcMock = () => supabase.rpc as ReturnType<typeof vi.fn>

    it('hace una sola llamada con las lineas de monto > 0 y la primera clave no vacia', async () => {
      rpcMock().mockResolvedValueOnce({
        data: { success: true, pagos: [{ id: '1', monto: 500 }] }, error: null,
      })

      const { result } = renderHook(() => usePagos())
      await act(async () => {
        await result.current.registrarPagosBatch({
          clienteId: 'c1',
          pedidoId: 'p1',
          fecha: '2026-08-05',
          pagos: [
            { formaPago: 'efectivo', monto: 0 },      // se filtra
            { formaPago: 'transferencia', monto: 500 },
            { formaPago: 'efectivo', monto: 200 },
          ],
          clientRequestIds: ['', 'uuid-linea-1', 'uuid-linea-2'],
        })
      })

      expect(supabase.rpc).toHaveBeenCalledTimes(1)
      expect(supabase.rpc).toHaveBeenCalledWith('registrar_pagos_pedido', expect.objectContaining({
        p_pedido_id: 'p1',
        p_fecha: '2026-08-05',
        p_metodos: [
          { monto: 500, forma_pago: 'transferencia' },
          { monto: 200, forma_pago: 'efectivo' },
        ],
        p_client_request_id: 'uuid-linea-1',
      }))
    })

    it('sin lineas con monto > 0 rechaza y no llama a la RPC', async () => {
      const { result } = renderHook(() => usePagos())
      await expect(act(async () => {
        await result.current.registrarPagosBatch({
          clienteId: 'c1', pedidoId: 'p1', fecha: '2026-08-05',
          pagos: [{ formaPago: 'efectivo', monto: 0 }],
        })
      })).rejects.toThrow(/No hay pagos validos/)

      expect(supabase.rpc).not.toHaveBeenCalled()
    })

    it('ante un replay idempotente devuelve las filas del intento anterior', async () => {
      const previos = [{ id: '10', monto: 300 }, { id: '11', monto: 200 }]
      rpcMock().mockResolvedValueOnce({
        data: { success: true, idempotent_replay: true, pagos: previos }, error: null,
      })

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

  // mig 230. Mandar `p_fecha: null` NO aplica el DEFAULT de la RPC: los defaults
  // de Postgres sólo valen cuando el argumento se OMITE. Llegaba p_fecha NULL y
  // el INSERT chocaba contra el NOT NULL de pagos.fecha.
  describe('registrarPagoFIFO / Combinado — p_fecha nunca viaja null', () => {
    const esFechaISO = expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/)

    it('sin fecha, manda la fecha local de Argentina en vez de null', async () => {
      ;(supabase.rpc as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
        data: { pago_ids: [1], sobrante: 0, monto_total: 500, aplicaciones: [], credito_aplicado: 0 },
        error: null,
      })

      const { result } = renderHook(() => usePagos())
      await act(async () => {
        await result.current.registrarPagoFIFO({
          clienteId: 'c1', monto: 500, formaPago: 'efectivo',
        })
      })

      expect(supabase.rpc).toHaveBeenCalledWith(
        'registrar_pago_cliente_fifo',
        expect.objectContaining({ p_fecha: esFechaISO }),
      )
    })

    it('respeta la fecha elegida cuando viene', async () => {
      ;(supabase.rpc as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
        data: { pago_ids: [1], sobrante: 0, monto_total: 500, aplicaciones: [], credito_aplicado: 0 },
        error: null,
      })

      const { result } = renderHook(() => usePagos())
      await act(async () => {
        await result.current.registrarPagoFIFO({
          clienteId: 'c1', monto: 500, formaPago: 'efectivo', fecha: '2026-03-01',
        })
      })

      expect(supabase.rpc).toHaveBeenCalledWith(
        'registrar_pago_cliente_fifo',
        expect.objectContaining({ p_fecha: '2026-03-01' }),
      )
    })

    it('el combinado tampoco manda null', async () => {
      ;(supabase.rpc as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
        data: { pago_ids: [1], sobrante: 0, monto_total: 500, aplicaciones: [], credito_aplicado: 0 },
        error: null,
      })

      const { result } = renderHook(() => usePagos())
      await act(async () => {
        await result.current.registrarPagoCombinadoFIFO({
          clienteId: 'c1',
          metodos: [{ monto: 300, formaPago: 'efectivo' }, { monto: 200, formaPago: 'transferencia' }],
        })
      })

      expect(supabase.rpc).toHaveBeenCalledWith(
        'registrar_pago_combinado_cliente_fifo',
        expect.objectContaining({ p_fecha: esFechaISO }),
      )
    })
  })

  describe('eliminarPago', () => {
    it('debe eliminar un pago y actualizar estado local', async () => {
      // First load pagos
      const mockPagos = [
        { id: '1', monto: 1000 },
        { id: '2', monto: 500 }
      ]
      mockRange.mockResolvedValueOnce({ data: mockPagos, error: null })

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

    it('fallback: un pedido anulado no suma a la deuda, igual que uno cancelado (#1080)', async () => {
      ;(supabase.rpc as ReturnType<typeof vi.fn>).mockResolvedValueOnce({ data: null, error: new Error('RPC not found') })
      mockSingle.mockResolvedValueOnce({ data: { id: 'c1', limite_credito: 0 }, error: null })
      mockRange
        .mockResolvedValueOnce({
          data: [
            { id: 1, estado: 'entregado', estado_pago: 'pendiente', total: 1000, created_at: '2026-09-01T10:00:00Z' },
            { id: 2, estado: 'cancelado', estado_pago: 'pendiente', total: 500, created_at: '2026-09-02T10:00:00Z' },
            { id: 3, estado: 'anulado', estado_pago: 'pendiente', total: 700, created_at: '2026-09-03T10:00:00Z' },
          ],
          error: null,
        })
        .mockResolvedValueOnce({ data: [], error: null })

      const { result } = renderHook(() => usePagos())

      let resumen: { total_compras: number; total_pedidos: number; saldo_actual: number; pedidos_pendientes_pago: number } | null = null
      await act(async () => {
        resumen = await result.current.obtenerResumenCuenta('c1') as typeof resumen
      })

      expect(resumen).toMatchObject({ total_compras: 1000, total_pedidos: 1, saldo_actual: 1000, pedidos_pendientes_pago: 1 })
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

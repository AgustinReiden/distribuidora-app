/**
 * Tests para PedidoService
 *
 * Verifies pedido operations: filtering, creation, state changes,
 * transportista assignment, deletion, delivery order, historial,
 * and statistics calculations.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest'

// ---------------------------------------------------------------------------
// Mocks -- hoisted to top by vitest before any imports
// ---------------------------------------------------------------------------

vi.mock('../../utils/logger', () => ({
  logger: { warn: vi.fn(), error: vi.fn(), info: vi.fn(), debug: vi.fn() }
}))

vi.mock('../../hooks/supabase/base', () => ({
  supabase: {
    from: vi.fn(() => ({
      select: vi.fn().mockReturnThis(),
      insert: vi.fn().mockReturnThis(),
      update: vi.fn().mockReturnThis(),
      delete: vi.fn().mockReturnThis(),
      eq: vi.fn().mockReturnThis(),
      neq: vi.fn().mockReturnThis(),
      gte: vi.fn().mockReturnThis(),
      lte: vi.fn().mockReturnThis(),
      lt: vi.fn().mockReturnThis(),
      gt: vi.fn().mockReturnThis(),
      or: vi.fn().mockReturnThis(),
      in: vi.fn().mockReturnThis(),
      order: vi.fn().mockReturnThis(),
      single: vi.fn().mockReturnThis(),
      limit: vi.fn().mockReturnThis(),
      is: vi.fn().mockReturnThis(),
      filter: vi.fn().mockReturnThis()
    })),
    rpc: vi.fn()
  },
  notifyError: vi.fn()
}))

// Import subjects under test -- mock wiring is already active
import { supabase, notifyError } from '../../hooks/supabase/base'
import { logger } from '../../utils/logger'
import { pedidoService } from '../api/pedidoService'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Creates a fresh chainable query mock where every builder method returns
 * `this` so chains like `.select().eq().order()` work.
 *
 * By default all terminal methods resolve to `{ data: null, error: null }`.
 * Pass overrides to control specific terminals.
 */
function chainable(overrides: Record<string, unknown> = {}) {
  const mock: Record<string, ReturnType<typeof vi.fn>> = {}
  const methods = [
    'select', 'insert', 'update', 'delete',
    'eq', 'neq', 'gte', 'lte', 'lt', 'gt',
    'or', 'in', 'order', 'single', 'limit',
    'is', 'filter', 'match', 'range', 'contains'
  ]
  for (const m of methods) {
    mock[m] = vi.fn().mockReturnThis()
  }
  // Apply overrides -- typically terminal methods that resolve
  for (const [key, val] of Object.entries(overrides)) {
    mock[key] = vi.fn(typeof val === 'function' ? (val as any) : () => val)
    // If the override is a plain value, make it resolve for await
    if (typeof val !== 'function') {
      mock[key].mockResolvedValue(val)
    }
  }
  return mock
}

/** Shortcut: make `supabase.rpc` resolve to `{ data, error: null }` */
function mockRpcSuccess(data: unknown) {
  vi.mocked(supabase.rpc).mockResolvedValue({ data, error: null } as any)
}

/** Shortcut: make `supabase.rpc` resolve to `{ data: null, error }` */
function mockRpcError(message: string) {
  vi.mocked(supabase.rpc).mockResolvedValue({
    data: null,
    error: { message, code: 'ERROR', details: '', hint: '' }
  } as any)
}

// ---------------------------------------------------------------------------
// Test suites
// ---------------------------------------------------------------------------

describe('PedidoService', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  // =========================================================================
  // getPedidosFiltrados
  // =========================================================================
  describe('getPedidosFiltrados', () => {
    it('should return all pedidos when no filters are provided', async () => {
      const pedidos = [
        { id: '1', estado: 'pendiente', total: 100 },
        { id: '2', estado: 'entregado', total: 200 }
      ]
      const mock = chainable({ order: { data: pedidos, error: null } })
      vi.mocked(supabase.from).mockReturnValue(mock as any)

      const result = await pedidoService.getPedidosFiltrados()

      expect(supabase.from).toHaveBeenCalledWith('pedidos')
      expect(mock.select).toHaveBeenCalled()
      expect(mock.order).toHaveBeenCalledWith('fecha_creacion', { ascending: false })
      // No filter methods should have been called
      expect(mock.eq).not.toHaveBeenCalled()
      expect(mock.gte).not.toHaveBeenCalled()
      expect(mock.lte).not.toHaveBeenCalled()
      expect(result).toEqual(pedidos)
    })

    it('should filter by estado', async () => {
      const mock = chainable({ order: { data: [], error: null } })
      vi.mocked(supabase.from).mockReturnValue(mock as any)

      await pedidoService.getPedidosFiltrados({ estado: 'pendiente' })

      expect(mock.eq).toHaveBeenCalledWith('estado', 'pendiente')
    })

    it('should skip estado filter when value is "todos"', async () => {
      const mock = chainable({ order: { data: [], error: null } })
      vi.mocked(supabase.from).mockReturnValue(mock as any)

      await pedidoService.getPedidosFiltrados({ estado: 'todos' })

      // eq should not have been called with 'estado'
      const eqCalls = mock.eq.mock.calls as unknown[][]
      const estadoCall = eqCalls.find((c) => c[0] === 'estado')
      expect(estadoCall).toBeUndefined()
    })

    it('should filter by clienteId', async () => {
      const mock = chainable({ order: { data: [], error: null } })
      vi.mocked(supabase.from).mockReturnValue(mock as any)

      await pedidoService.getPedidosFiltrados({ clienteId: 'client-abc' })

      expect(mock.eq).toHaveBeenCalledWith('cliente_id', 'client-abc')
    })

    it('should filter by date range (fechaDesde and fechaHasta)', async () => {
      const mock = chainable({ order: { data: [], error: null } })
      vi.mocked(supabase.from).mockReturnValue(mock as any)

      await pedidoService.getPedidosFiltrados({
        fechaDesde: '2026-01-01',
        fechaHasta: '2026-01-31'
      })

      expect(mock.gte).toHaveBeenCalledWith('fecha_creacion', '2026-01-01')
      expect(mock.lte).toHaveBeenCalledWith('fecha_creacion', '2026-01-31')
    })

    it('should apply multiple filters simultaneously', async () => {
      const mock = chainable({ order: { data: [], error: null } })
      vi.mocked(supabase.from).mockReturnValue(mock as any)

      await pedidoService.getPedidosFiltrados({
        estado: 'en_reparto',
        transportistaId: 'transp-1',
        metodoPago: 'efectivo'
      })

      expect(mock.eq).toHaveBeenCalledWith('estado', 'en_reparto')
      expect(mock.eq).toHaveBeenCalledWith('transportista_id', 'transp-1')
      expect(mock.eq).toHaveBeenCalledWith('metodo_pago', 'efectivo')
    })
  })

  // =========================================================================
  // crearPedidoCompleto
  // =========================================================================
  describe('crearPedidoCompleto', () => {
    const pedidoData = {
      cliente_id: 'client-1',
      preventista_id: 'prev-1',
      notas: 'Entregar por la tarde',
      metodo_pago: 'efectivo',
      descuento: 10
    }

    const items = [
      { producto_id: 'prod-1', cantidad: 5, precio_unitario: 100 },
      { producto_id: 'prod-2', cantidad: 2, precio_unitario: 250 }
    ]

    it('should call RPC crear_pedido_completo with correct params and return the pedido', async () => {
      const createdPedido = { id: 'ped-1', estado: 'pendiente', total: 1000 }
      mockRpcSuccess(createdPedido)

      const result = await pedidoService.crearPedidoCompleto(pedidoData, items)

      expect(supabase.rpc).toHaveBeenCalledWith('crear_pedido_completo', {
        p_cliente_id: 'client-1',
        p_preventista_id: 'prev-1',
        p_items: JSON.stringify(items),
        p_notas: 'Entregar por la tarde',
        p_metodo_pago: 'efectivo',
        p_descuento: 10
      })
      expect(result).toEqual(createdPedido)
    })

    it('should throw when the RPC returns an error', async () => {
      mockRpcError('Stock insuficiente para producto X')

      await expect(
        pedidoService.crearPedidoCompleto(pedidoData, items)
      ).rejects.toThrow('Error en operación crear_pedido_completo')
    })

    it('should use default values for optional pedidoData fields', async () => {
      mockRpcSuccess({ id: 'ped-2' })

      await pedidoService.crearPedidoCompleto({ cliente_id: 'c-1' }, items)

      expect(supabase.rpc).toHaveBeenCalledWith(
        'crear_pedido_completo',
        expect.objectContaining({
          p_notas: '',
          p_metodo_pago: 'efectivo',
          p_descuento: 0
        })
      )
    })
  })

  // =========================================================================
  // cambiarEstado
  // =========================================================================
  describe('cambiarEstado', () => {
    it('should update to a valid estado and register historial', async () => {
      const updatedPedido = { id: 'ped-1', estado: 'en_preparacion' }

      // from('pedidos') -> update chain -> single resolves
      const pedidosMock = chainable({ single: { data: updatedPedido, error: null } })
      // from('pedido_historial') -> insert resolves
      const historialMock = chainable()
      historialMock.insert = vi.fn().mockResolvedValue({ data: null, error: null })

      vi.mocked(supabase.from).mockImplementation((table: string) => {
        if (table === 'pedido_historial') return historialMock as any
        return pedidosMock as any
      })

      const result = await pedidoService.cambiarEstado('ped-1', 'en_preparacion', 'Preparando')

      expect(result).toEqual(updatedPedido)
      expect(pedidosMock.update).toHaveBeenCalledWith({ estado: 'en_preparacion' })
      expect(historialMock.insert).toHaveBeenCalledWith(
        expect.objectContaining({
          pedido_id: 'ped-1',
          accion: 'en_preparacion',
          descripcion: 'Preparando'
        })
      )
    })

    it('should throw for an invalid estado', async () => {
      await expect(
        pedidoService.cambiarEstado('ped-1', 'invalido' as any)
      ).rejects.toThrow('Estado inválido: invalido')

      // No DB calls should have been made
      expect(supabase.from).not.toHaveBeenCalled()
    })

    it('should set fecha_entrega when estado is "entregado"', async () => {
      const updatedPedido = { id: 'ped-1', estado: 'entregado' }
      const pedidosMock = chainable({ single: { data: updatedPedido, error: null } })
      const historialMock = chainable()
      historialMock.insert = vi.fn().mockResolvedValue({ data: null, error: null })

      vi.mocked(supabase.from).mockImplementation((table: string) => {
        if (table === 'pedido_historial') return historialMock as any
        return pedidosMock as any
      })

      await pedidoService.cambiarEstado('ped-1', 'entregado')

      // Capture the object passed to update()
      const updateArg = pedidosMock.update.mock.calls[0][0]
      expect(updateArg.estado).toBe('entregado')
      expect(updateArg.fecha_entrega).toBeDefined()
      // fecha_entrega should be a valid ISO date string
      expect(new Date(updateArg.fecha_entrega).toISOString()).toBe(updateArg.fecha_entrega)
    })
  })

  // =========================================================================
  // asignarTransportista
  // =========================================================================
  describe('asignarTransportista', () => {
    it('should update with transportista_id and estado en_reparto, then register historial', async () => {
      const updatedPedido = { id: 'ped-1', transportista_id: 'transp-1', estado: 'en_reparto' }
      const pedidosMock = chainable({ single: { data: updatedPedido, error: null } })
      const historialMock = chainable()
      historialMock.insert = vi.fn().mockResolvedValue({ data: null, error: null })

      vi.mocked(supabase.from).mockImplementation((table: string) => {
        if (table === 'pedido_historial') return historialMock as any
        return pedidosMock as any
      })

      const result = await pedidoService.asignarTransportista('ped-1', 'transp-1')

      expect(result).toEqual(updatedPedido)
      expect(pedidosMock.update).toHaveBeenCalledWith({
        transportista_id: 'transp-1',
        estado: 'en_reparto'
      })
      expect(historialMock.insert).toHaveBeenCalledWith(
        expect.objectContaining({
          pedido_id: 'ped-1',
          accion: 'transportista_asignado',
          descripcion: 'Transportista asignado: transp-1'
        })
      )
    })
  })

  // =========================================================================
  // eliminarPedido
  // =========================================================================
  describe('eliminarPedido', () => {
    it('should call RPC eliminar_pedido_completo with correct params', async () => {
      mockRpcSuccess(true)

      const result = await pedidoService.eliminarPedido('ped-1', true, 'Duplicado')

      expect(supabase.rpc).toHaveBeenCalledWith('eliminar_pedido_completo', {
        p_pedido_id: 'ped-1',
        p_restaurar_stock: true,
        p_motivo: 'Duplicado'
      })
      expect(result).toBe(true)
    })

    it('should use default values for restaurarStock and motivo', async () => {
      mockRpcSuccess(true)

      await pedidoService.eliminarPedido('ped-2')

      expect(supabase.rpc).toHaveBeenCalledWith('eliminar_pedido_completo', {
        p_pedido_id: 'ped-2',
        p_restaurar_stock: true,
        p_motivo: ''
      })
    })
  })

  // =========================================================================
  // actualizarOrdenEntrega
  // =========================================================================
  describe('actualizarOrdenEntrega', () => {
    const ordenes = [
      { pedido_id: 'ped-1', orden_entrega: 1 },
      { pedido_id: 'ped-2', orden_entrega: 2 },
      { pedido_id: 'ped-3', orden_entrega: 3 }
    ]

    it('should call RPC actualizar_orden_entrega_batch on success', async () => {
      mockRpcSuccess(true)

      const result = await pedidoService.actualizarOrdenEntrega(ordenes)

      expect(supabase.rpc).toHaveBeenCalledWith('actualizar_orden_entrega_batch', {
        ordenes: JSON.stringify(ordenes)
      })
      expect(result).toBe(true)
    })

    it('should fall back to individual updates when RPC fails', async () => {
      // Make the RPC reject so the catch block triggers
      mockRpcError('function does not exist')

      // The fallback calls this.update() for each orden
      const pedidosMock = chainable({ single: { data: { id: 'x' }, error: null } })
      vi.mocked(supabase.from).mockReturnValue(pedidosMock as any)

      const result = await pedidoService.actualizarOrdenEntrega(ordenes)

      expect(result).toBe(true)
      // update should have been called once per orden
      expect(pedidosMock.update).toHaveBeenCalledTimes(3)
      expect(pedidosMock.update).toHaveBeenCalledWith({ orden_entrega: 1 })
      expect(pedidosMock.update).toHaveBeenCalledWith({ orden_entrega: 2 })
      expect(pedidosMock.update).toHaveBeenCalledWith({ orden_entrega: 3 })
    })
  })

  // =========================================================================
  // actualizarItems
  // =========================================================================
  describe('actualizarItems', () => {
    it('should call RPC actualizar_pedido_items with correct params', async () => {
      const nuevosItems = [
        { producto_id: 'prod-1', cantidad: 10, precio_unitario: 50 }
      ]
      const updatedPedido = { id: 'ped-1', total: 500 }
      mockRpcSuccess(updatedPedido)

      const result = await pedidoService.actualizarItems('ped-1', nuevosItems)

      expect(supabase.rpc).toHaveBeenCalledWith('actualizar_pedido_items', {
        p_pedido_id: 'ped-1',
        p_items: JSON.stringify(nuevosItems)
      })
      expect(result).toEqual(updatedPedido)
    })
  })

  // =========================================================================
  // registrarHistorial
  // =========================================================================
  describe('registrarHistorial', () => {
    it('should insert into pedido_historial and not throw on insert error', async () => {
      const historialMock = chainable()
      historialMock.insert = vi.fn().mockRejectedValue(new Error('insert failed'))

      vi.mocked(supabase.from).mockImplementation((table: string) => {
        if (table === 'pedido_historial') return historialMock as any
        return chainable() as any
      })

      // Should NOT throw -- errors are caught silently
      await expect(
        pedidoService.registrarHistorial('ped-1', 'test_action', 'test description')
      ).resolves.toBeUndefined()

      expect(historialMock.insert).toHaveBeenCalledWith(
        expect.objectContaining({
          pedido_id: 'ped-1',
          accion: 'test_action',
          descripcion: 'test description'
        })
      )
      expect(logger.warn).toHaveBeenCalled()
    })
  })

  // =========================================================================
  // getHistorial
  // =========================================================================
  describe('getHistorial', () => {
    it('should query pedido_historial filtered by pedido_id ordered by fecha desc', async () => {
      const historial = [
        { id: 'h-1', pedido_id: 'ped-1', accion: 'entregado', descripcion: '', fecha: '2026-02-09' },
        { id: 'h-2', pedido_id: 'ped-1', accion: 'pendiente', descripcion: '', fecha: '2026-02-08' }
      ]
      const historialMock = chainable({ order: { data: historial, error: null } })

      vi.mocked(supabase.from).mockImplementation((table: string) => {
        if (table === 'pedido_historial') return historialMock as any
        return chainable() as any
      })

      const result = await pedidoService.getHistorial('ped-1')

      expect(supabase.from).toHaveBeenCalledWith('pedido_historial')
      expect(historialMock.select).toHaveBeenCalledWith('*')
      expect(historialMock.eq).toHaveBeenCalledWith('pedido_id', 'ped-1')
      expect(historialMock.order).toHaveBeenCalledWith('fecha', { ascending: false })
      expect(result).toEqual(historial)
    })

    it('should return empty array on error', async () => {
      const historialMock = chainable({ order: { data: null, error: new Error('DB error') } })

      vi.mocked(supabase.from).mockImplementation((table: string) => {
        if (table === 'pedido_historial') return historialMock as any
        return chainable() as any
      })

      const result = await pedidoService.getHistorial('ped-1')

      expect(result).toEqual([])
      expect(notifyError).toHaveBeenCalled()
    })
  })

  // =========================================================================
  // getEstadisticas
  // =========================================================================
  describe('getEstadisticas', () => {
    it('should calculate statistics correctly from pedido data', async () => {
      const pedidos = [
        { id: '1', estado: 'pendiente', total: 100 },
        { id: '2', estado: 'pendiente', total: 200 },
        { id: '3', estado: 'entregado', total: 300 },
        { id: '4', estado: 'entregado', total: 500 },
        { id: '5', estado: 'cancelado', total: 50 },
        { id: '6', estado: 'en_preparacion', total: 150 }
      ]

      // getEstadisticas does: from('pedidos').select('*') then awaits
      // The last call in the non-filtered path is `select`, which is also
      // the awaitable.  But Supabase query builder is `then`-able. In our
      // mock the chain goes: from -> select (if no gte/lte) then await.
      // We need select to resolve:
      const mock = chainable({ select: { data: pedidos, error: null } })
      vi.mocked(supabase.from).mockReturnValue(mock as any)

      const stats = await pedidoService.getEstadisticas()

      expect(stats.total).toBe(6)
      expect(stats.porEstado).toEqual({
        pendiente: 2,
        entregado: 2,
        cancelado: 1,
        en_preparacion: 1
      })
      // totalVentas = sum of totals for entregados only: 300 + 500
      expect(stats.totalVentas).toBe(800)
      // promedioTicket = 800 / 2
      expect(stats.promedioTicket).toBe(400)
      expect(stats.pendientes).toBe(2)
      expect(stats.entregados).toBe(2)
    })

    it('should apply date filters when desde and hasta are provided', async () => {
      const mock = chainable()
      // When gte/lte are chained, the terminal `await` still resolves through
      // the last method call.  Since lte is last, make it resolve.
      mock.lte = vi.fn().mockResolvedValue({ data: [], error: null })
      vi.mocked(supabase.from).mockReturnValue(mock as any)

      const desde = new Date('2026-01-01T00:00:00Z')
      const hasta = new Date('2026-01-31T23:59:59Z')

      await pedidoService.getEstadisticas(desde, hasta)

      expect(mock.gte).toHaveBeenCalledWith('fecha_creacion', desde.toISOString())
      expect(mock.lte).toHaveBeenCalledWith('fecha_creacion', hasta.toISOString())
    })

    it('should return zero-value statistics on error', async () => {
      const mock = chainable({ select: { data: null, error: new Error('Query failed') } })
      vi.mocked(supabase.from).mockReturnValue(mock as any)

      const stats = await pedidoService.getEstadisticas()

      expect(stats).toEqual({
        total: 0,
        porEstado: {},
        totalVentas: 0,
        promedioTicket: 0,
        pendientes: 0,
        entregados: 0
      })
    })

    it('should handle zero entregados without division by zero', async () => {
      const pedidos = [
        { id: '1', estado: 'pendiente', total: 100 },
        { id: '2', estado: 'cancelado', total: 200 }
      ]
      const mock = chainable({ select: { data: pedidos, error: null } })
      vi.mocked(supabase.from).mockReturnValue(mock as any)

      const stats = await pedidoService.getEstadisticas()

      expect(stats.totalVentas).toBe(0)
      expect(stats.promedioTicket).toBe(0)
      expect(stats.entregados).toBe(0)
      expect(stats.pendientes).toBe(1)
    })
  })
})

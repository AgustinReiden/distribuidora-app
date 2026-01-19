/**
 * Tests para usePedidos hook
 *
 * Cobertura:
 * - Estado inicial y carga
 * - Fetch de pedidos con éxito y error
 * - Filtrado de pedidos
 * - CRUD de pedidos
 * - Cambio de estado y asignación de transportista
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor, act } from '@testing-library/react'

// Mock de base.js con factory inline
vi.mock('./base', () => {
  const mockNotifyError = vi.fn()
  return {
    supabase: {
      from: vi.fn(),
      rpc: vi.fn()
    },
    notifyError: mockNotifyError
  }
})

import { usePedidos } from './usePedidos'
import { supabase, notifyError } from './base'

// Datos de prueba
const mockCliente = {
  id: 'cliente-1',
  nombre_fantasia: 'Cliente Test',
  razon_social: 'Test SA',
  direccion: 'Calle Test 123'
}

const mockProducto = {
  id: 'producto-1',
  nombre: 'Producto Test',
  precio: 100,
  stock: 50
}

const mockPedido = {
  id: 'pedido-1',
  cliente_id: 'cliente-1',
  cliente: mockCliente,
  total: 500,
  estado: 'pendiente',
  estado_pago: 'pendiente',
  forma_pago: 'efectivo',
  usuario_id: 'user-1',
  transportista_id: null,
  created_at: '2024-01-15T10:00:00Z',
  items: [
    {
      id: 'item-1',
      producto_id: 'producto-1',
      producto: mockProducto,
      cantidad: 5,
      precio_unitario: 100,
      subtotal: 500
    }
  ]
}

const mockPedido2 = {
  id: 'pedido-2',
  cliente_id: 'cliente-2',
  cliente: { ...mockCliente, id: 'cliente-2', nombre_fantasia: 'Cliente 2' },
  total: 1000,
  estado: 'entregado',
  estado_pago: 'pagado',
  forma_pago: 'transferencia',
  usuario_id: 'user-1',
  transportista_id: 'transport-1',
  created_at: '2024-01-16T10:00:00Z',
  items: []
}

const mockPerfil = {
  id: 'user-1',
  nombre: 'Usuario Test',
  email: 'test@example.com'
}

// Helper para crear mock chain de supabase
const createMockChain = (data, error = null) => ({
  select: vi.fn().mockReturnThis(),
  eq: vi.fn().mockReturnThis(),
  in: vi.fn().mockReturnThis(),
  order: vi.fn().mockReturnThis(),
  maybeSingle: vi.fn().mockResolvedValue({ data, error }),
  single: vi.fn().mockResolvedValue({ data, error }),
  then: vi.fn().mockImplementation(cb => Promise.resolve(cb({ data, error }))),
  delete: vi.fn().mockReturnThis(),
  update: vi.fn().mockReturnThis(),
  insert: vi.fn().mockResolvedValue({ data, error })
})

describe('usePedidos', () => {
  beforeEach(() => {
    vi.clearAllMocks()

    // Mock por defecto: fetch vacío
    const emptyChain = createMockChain([])
    supabase.from.mockReturnValue(emptyChain)
  })

  describe('Estado inicial', () => {
    it('inicia con loading true y pedidos vacíos', async () => {
      const { result } = renderHook(() => usePedidos())

      expect(result.current.loading).toBe(true)
      expect(result.current.pedidos).toEqual([])
    })

    it('tiene filtros con valores por defecto', async () => {
      const { result } = renderHook(() => usePedidos())

      expect(result.current.filtros).toEqual({
        fechaDesde: null,
        fechaHasta: null,
        estado: 'todos',
        estadoPago: 'todos',
        transportistaId: 'todos',
        busqueda: ''
      })
    })
  })

  describe('fetchPedidos', () => {
    it('carga pedidos correctamente', async () => {
      // Mock para pedidos
      const pedidosChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: [mockPedido], error: null })
      }

      // Mock para perfiles
      const perfilesChain = {
        select: vi.fn().mockReturnThis(),
        in: vi.fn().mockResolvedValue({ data: [mockPerfil], error: null })
      }

      supabase.from.mockImplementation((table) => {
        if (table === 'pedidos') return pedidosChain
        if (table === 'perfiles') return perfilesChain
        return createMockChain([])
      })

      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      expect(result.current.pedidos).toHaveLength(1)
      expect(result.current.pedidos[0].id).toBe('pedido-1')
    })

    it('maneja errores de fetch', async () => {
      const pedidosChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: null, error: { message: 'Error de red' } })
      }

      supabase.from.mockReturnValue(pedidosChain)

      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      expect(result.current.pedidos).toEqual([])
    })

    it('mapea perfiles a pedidos correctamente', async () => {
      const pedidoConUsuario = {
        ...mockPedido,
        usuario_id: 'user-1',
        transportista_id: 'transport-1'
      }

      const transportistaPerfil = {
        id: 'transport-1',
        nombre: 'Transportista Test',
        email: 'transport@test.com'
      }

      const pedidosChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: [pedidoConUsuario], error: null })
      }

      const perfilesChain = {
        select: vi.fn().mockReturnThis(),
        in: vi.fn().mockResolvedValue({
          data: [mockPerfil, transportistaPerfil],
          error: null
        })
      }

      supabase.from.mockImplementation((table) => {
        if (table === 'pedidos') return pedidosChain
        if (table === 'perfiles') return perfilesChain
        return createMockChain([])
      })

      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      expect(result.current.pedidos[0].usuario).toEqual(mockPerfil)
      expect(result.current.pedidos[0].transportista).toEqual(transportistaPerfil)
    })
  })

  describe('pedidosFiltrados', () => {
    beforeEach(async () => {
      const pedidosChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: [mockPedido, mockPedido2], error: null })
      }

      const perfilesChain = {
        select: vi.fn().mockReturnThis(),
        in: vi.fn().mockResolvedValue({ data: [mockPerfil], error: null })
      }

      supabase.from.mockImplementation((table) => {
        if (table === 'pedidos') return pedidosChain
        if (table === 'perfiles') return perfilesChain
        return createMockChain([])
      })
    })

    it('filtra por estado', async () => {
      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      // Filtrar por estado pendiente
      act(() => {
        result.current.setFiltros({ ...result.current.filtros, estado: 'pendiente' })
      })

      const filtrados = result.current.pedidosFiltrados()
      expect(filtrados).toHaveLength(1)
      expect(filtrados[0].estado).toBe('pendiente')
    })

    it('filtra por estado de pago', async () => {
      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      act(() => {
        result.current.setFiltros({ ...result.current.filtros, estadoPago: 'pagado' })
      })

      const filtrados = result.current.pedidosFiltrados()
      expect(filtrados).toHaveLength(1)
      expect(filtrados[0].estado_pago).toBe('pagado')
    })

    it('filtra por transportista asignado', async () => {
      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      act(() => {
        result.current.setFiltros({ ...result.current.filtros, transportistaId: 'transport-1' })
      })

      const filtrados = result.current.pedidosFiltrados()
      expect(filtrados).toHaveLength(1)
      expect(filtrados[0].transportista_id).toBe('transport-1')
    })

    it('filtra por pedidos sin transportista', async () => {
      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      act(() => {
        result.current.setFiltros({ ...result.current.filtros, transportistaId: 'sin_asignar' })
      })

      const filtrados = result.current.pedidosFiltrados()
      expect(filtrados).toHaveLength(1)
      expect(filtrados[0].transportista_id).toBeNull()
    })

    it('filtra por rango de fechas', async () => {
      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      act(() => {
        result.current.setFiltros({
          ...result.current.filtros,
          fechaDesde: '2024-01-16',
          fechaHasta: '2024-01-16'
        })
      })

      const filtrados = result.current.pedidosFiltrados()
      expect(filtrados).toHaveLength(1)
      expect(filtrados[0].id).toBe('pedido-2')
    })

    it('retorna todos con filtros por defecto', async () => {
      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      const filtrados = result.current.pedidosFiltrados()
      expect(filtrados).toHaveLength(2)
    })
  })

  describe('crearPedido', () => {
    it('crea pedido con RPC exitoso', async () => {
      supabase.rpc.mockResolvedValue({
        data: { success: true, pedido_id: 'nuevo-pedido-1' },
        error: null
      })

      const pedidosChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: [], error: null })
      }
      supabase.from.mockReturnValue(pedidosChain)

      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      const items = [{ productoId: 'producto-1', cantidad: 5, precioUnitario: 100 }]
      let createdPedido

      await act(async () => {
        createdPedido = await result.current.crearPedido(
          'cliente-1',
          items,
          500,
          'user-1',
          vi.fn(),
          'Notas test',
          'efectivo',
          'pendiente'
        )
      })

      expect(createdPedido.id).toBe('nuevo-pedido-1')
      expect(supabase.rpc).toHaveBeenCalledWith('crear_pedido_completo', expect.objectContaining({
        p_cliente_id: 'cliente-1',
        p_total: 500,
        p_usuario_id: 'user-1'
      }))
    })

    it('lanza error cuando RPC falla', async () => {
      supabase.rpc.mockResolvedValue({
        data: { success: false, errores: ['Stock insuficiente'] },
        error: null
      })

      const pedidosChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: [], error: null })
      }
      supabase.from.mockReturnValue(pedidosChain)

      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      const items = [{ productoId: 'producto-1', cantidad: 100, precioUnitario: 100 }]

      await expect(
        act(async () => {
          await result.current.crearPedido('cliente-1', items, 10000, 'user-1', vi.fn())
        })
      ).rejects.toThrow('Stock insuficiente')
    })
  })

  describe('cambiarEstado', () => {
    it('cambia estado de pedido', async () => {
      const pedidosChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: [mockPedido], error: null }),
        update: vi.fn().mockReturnThis(),
        eq: vi.fn().mockResolvedValue({ error: null })
      }

      supabase.from.mockReturnValue(pedidosChain)

      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      await act(async () => {
        await result.current.cambiarEstado('pedido-1', 'en_preparacion')
      })

      expect(pedidosChain.update).toHaveBeenCalledWith(expect.objectContaining({
        estado: 'en_preparacion'
      }))
    })

    it('agrega fecha_entrega cuando estado es entregado', async () => {
      const pedidosChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: [mockPedido], error: null }),
        update: vi.fn().mockReturnThis(),
        eq: vi.fn().mockResolvedValue({ error: null })
      }

      supabase.from.mockReturnValue(pedidosChain)

      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      await act(async () => {
        await result.current.cambiarEstado('pedido-1', 'entregado')
      })

      expect(pedidosChain.update).toHaveBeenCalledWith(expect.objectContaining({
        estado: 'entregado',
        fecha_entrega: expect.any(String)
      }))
    })
  })

  describe('asignarTransportista', () => {
    it('asigna transportista a pedido', async () => {
      const pedidosChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: [mockPedido], error: null }),
        update: vi.fn().mockReturnThis(),
        eq: vi.fn().mockResolvedValue({ error: null })
      }

      supabase.from.mockReturnValue(pedidosChain)

      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      await act(async () => {
        await result.current.asignarTransportista('pedido-1', 'transport-1')
      })

      expect(pedidosChain.update).toHaveBeenCalledWith(expect.objectContaining({
        transportista_id: 'transport-1'
      }))
    })

    it('cambia estado a asignado cuando se indica', async () => {
      const pedidosChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: [mockPedido], error: null }),
        update: vi.fn().mockReturnThis(),
        eq: vi.fn().mockResolvedValue({ error: null })
      }

      supabase.from.mockReturnValue(pedidosChain)

      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      await act(async () => {
        await result.current.asignarTransportista('pedido-1', 'transport-1', true)
      })

      expect(pedidosChain.update).toHaveBeenCalledWith(expect.objectContaining({
        transportista_id: 'transport-1',
        estado: 'asignado'
      }))
    })
  })

  describe('actualizarEstadoPago', () => {
    it('actualiza estado de pago', async () => {
      const pedidosChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: [mockPedido], error: null }),
        update: vi.fn().mockReturnThis(),
        eq: vi.fn().mockResolvedValue({ error: null })
      }

      supabase.from.mockReturnValue(pedidosChain)

      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      await act(async () => {
        await result.current.actualizarEstadoPago('pedido-1', 'pagado', 500)
      })

      expect(pedidosChain.update).toHaveBeenCalledWith({
        estado_pago: 'pagado',
        monto_pagado: 500
      })
    })
  })

  describe('actualizarNotasPedido', () => {
    it('actualiza notas del pedido', async () => {
      const pedidosChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: [mockPedido], error: null }),
        update: vi.fn().mockReturnThis(),
        eq: vi.fn().mockResolvedValue({ error: null })
      }

      supabase.from.mockReturnValue(pedidosChain)

      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      await act(async () => {
        await result.current.actualizarNotasPedido('pedido-1', 'Nuevas notas')
      })

      expect(pedidosChain.update).toHaveBeenCalledWith({ notas: 'Nuevas notas' })
    })
  })

  describe('fetchHistorialPedido', () => {
    it('obtiene historial de pedido', async () => {
      const historialData = [
        { id: 'hist-1', pedido_id: 'pedido-1', accion: 'creado', created_at: '2024-01-15T10:00:00Z' }
      ]

      const historialChain = {
        select: vi.fn().mockReturnThis(),
        eq: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: historialData, error: null })
      }

      supabase.from.mockImplementation((table) => {
        if (table === 'pedido_historial') return historialChain
        return {
          select: vi.fn().mockReturnThis(),
          order: vi.fn().mockResolvedValue({ data: [], error: null })
        }
      })

      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      let historial
      await act(async () => {
        historial = await result.current.fetchHistorialPedido('pedido-1')
      })

      expect(historial).toHaveLength(1)
      expect(historial[0].accion).toBe('creado')
    })

    it('retorna array vacío en error', async () => {
      const historialChain = {
        select: vi.fn().mockReturnThis(),
        eq: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: null, error: { message: 'Error' } })
      }

      supabase.from.mockImplementation((table) => {
        if (table === 'pedido_historial') return historialChain
        return {
          select: vi.fn().mockReturnThis(),
          order: vi.fn().mockResolvedValue({ data: [], error: null })
        }
      })

      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      let historial
      await act(async () => {
        historial = await result.current.fetchHistorialPedido('pedido-1')
      })

      expect(historial).toEqual([])
      expect(notifyError).toHaveBeenCalled()
    })
  })

  describe('refetch', () => {
    it('permite refrescar pedidos manualmente', async () => {
      let callCount = 0
      const pedidosChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockImplementation(() => {
          callCount++
          // Primera llamada retorna 1 pedido, segunda retorna 2
          if (callCount === 1) {
            return Promise.resolve({ data: [mockPedido], error: null })
          }
          return Promise.resolve({ data: [mockPedido, mockPedido2], error: null })
        })
      }

      const perfilesChain = {
        select: vi.fn().mockReturnThis(),
        in: vi.fn().mockResolvedValue({ data: [mockPerfil], error: null })
      }

      supabase.from.mockImplementation((table) => {
        if (table === 'pedidos') return pedidosChain
        if (table === 'perfiles') return perfilesChain
        return createMockChain([])
      })

      const { result } = renderHook(() => usePedidos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      expect(result.current.pedidos).toHaveLength(1)

      await act(async () => {
        await result.current.refetch()
      })

      await waitFor(() => {
        expect(result.current.pedidos).toHaveLength(2)
      })
    })
  })
})

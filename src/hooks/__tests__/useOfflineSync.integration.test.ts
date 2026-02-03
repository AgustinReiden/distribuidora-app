/**
 * Tests de Integración para useOfflineSync
 *
 * Escenarios críticos:
 * - SYNC-01: Guardar pedido offline → reconectar → sincronizar exitosamente
 * - SYNC-02: Conflicto de stock: pedido offline con stock insuficiente al sincronizar
 * - SYNC-03: Sincronización parcial: algunos pedidos fallan
 * - SYNC-04: Race condition: doble click en sincronizar
 * - SYNC-05: Guardar y sincronizar mermas
 * - SYNC-06: Migración de datos legacy
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'
import { useOfflineSync } from '../useOfflineSync'
import type { PedidoOffline, ProductoDB } from '../../types'

// Mock de offlineDb (ahora useOfflineSync usa IndexedDB via offlineDb)
const mockQueueOperation = vi.fn().mockResolvedValue(1)
const mockGetPendingOperations = vi.fn().mockResolvedValue([])
const mockMarkAsCompleted = vi.fn().mockResolvedValue(undefined)
const mockMarkAsFailed = vi.fn().mockResolvedValue(undefined)
const mockCleanupOldOperations = vi.fn().mockResolvedValue(0)

vi.mock('../../lib/offlineDb', () => ({
  queueOperation: (...args: unknown[]) => mockQueueOperation(...args),
  getPendingOperations: (...args: unknown[]) => mockGetPendingOperations(...args),
  markAsCompleted: (...args: unknown[]) => mockMarkAsCompleted(...args),
  markAsFailed: (...args: unknown[]) => mockMarkAsFailed(...args),
  cleanupOldOperations: (...args: unknown[]) => mockCleanupOldOperations(...args),
}))

describe('useOfflineSync Integration Tests', () => {
  // Productos de prueba
  const mockProductos: ProductoDB[] = [
    { id: 'p1', nombre: 'Producto 1', stock: 10, precio_final: 100, activo: true } as ProductoDB,
    { id: 'p2', nombre: 'Producto 2', stock: 5, precio_final: 200, activo: true } as ProductoDB,
    { id: 'p3', nombre: 'Producto 3', stock: 0, precio_final: 300, activo: true } as ProductoDB
  ]

  // Mock de funciones de API
  const mockCrearPedido = vi.fn()
  const mockDescontarStock = vi.fn()
  const mockRegistrarMerma = vi.fn()

  beforeEach(() => {
    vi.clearAllMocks()

    // Simular estado online por defecto
    Object.defineProperty(navigator, 'onLine', {
      value: true,
      writable: true,
      configurable: true
    })

    // Reset mocks de offlineDb
    mockQueueOperation.mockResolvedValue(1)
    mockGetPendingOperations.mockResolvedValue([])
    mockMarkAsCompleted.mockResolvedValue(undefined)
    mockMarkAsFailed.mockResolvedValue(undefined)
    mockCleanupOldOperations.mockResolvedValue(0)

    // Reset mocks de API
    mockCrearPedido.mockResolvedValue({ id: 1, success: true })
    mockDescontarStock.mockResolvedValue(undefined)
    mockRegistrarMerma.mockResolvedValue({ id: 1, success: true })
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  // ===========================================================================
  // SYNC-01: Flujo completo de sincronización exitosa
  // ===========================================================================
  describe('SYNC-01: Sincronización exitosa de pedido offline', () => {
    it('debe guardar pedido offline y sincronizar cuando vuelve la conexión', async () => {
      // Start with no pending operations
      mockGetPendingOperations.mockResolvedValue([])

      const { result } = renderHook(() => useOfflineSync())

      // Esperar carga inicial
      await waitFor(() => {
        expect(result.current.pedidosPendientes).toEqual([])
      })

      // Simular offline
      act(() => {
        Object.defineProperty(navigator, 'onLine', { value: false, configurable: true })
        window.dispatchEvent(new Event('offline'))
      })

      expect(result.current.isOnline).toBe(false)

      // Guardar pedido offline
      const pedidoData = {
        clienteId: '123',
        items: [{ productoId: 'p1', cantidad: 2, precioUnitario: 100 }],
        total: 200,
        usuarioId: 'user1'
      }

      let saveResult: ReturnType<typeof result.current.guardarPedidoOffline>
      act(() => {
        saveResult = result.current.guardarPedidoOffline(pedidoData, {
          productos: mockProductos,
          validarStock: true
        })
      })

      expect(saveResult!.success).toBe(true)
      expect(saveResult!.pedido).toBeDefined()
      expect(result.current.pedidosPendientes).toHaveLength(1)

      // Mock getPendingOperations to return the saved pedido for sync
      const mockPendingOp = {
        id: 1,
        type: 'CREATE_PEDIDO',
        status: 'pending',
        payload: pedidoData,
        createdAt: new Date()
      }
      mockGetPendingOperations.mockResolvedValue([mockPendingOp])

      // Simular reconexión
      act(() => {
        Object.defineProperty(navigator, 'onLine', { value: true, configurable: true })
        window.dispatchEvent(new Event('online'))
      })

      expect(result.current.isOnline).toBe(true)

      // After sync, no more pending operations
      mockGetPendingOperations.mockResolvedValueOnce([mockPendingOp]).mockResolvedValue([])

      // Sincronizar
      let syncResult: Awaited<ReturnType<typeof result.current.sincronizarPedidos>>
      await act(async () => {
        syncResult = await result.current.sincronizarPedidos(mockCrearPedido, mockDescontarStock)
      })

      expect(syncResult!.success).toBe(true)
      expect(syncResult!.sincronizados).toBe(1)
      expect(syncResult!.errores).toHaveLength(0)
      expect(mockCrearPedido).toHaveBeenCalledTimes(1)
      expect(result.current.pedidosPendientes).toHaveLength(0)
    })

    it('debe persistir pedidos en IndexedDB via queueOperation', async () => {
      const { result } = renderHook(() => useOfflineSync())

      await waitFor(() => {
        expect(result.current.pedidosPendientes).toEqual([])
      })

      const pedidoData = {
        clienteId: '456',
        items: [{ productoId: 'p2', cantidad: 1, precioUnitario: 200 }],
        total: 200
      }

      act(() => {
        result.current.guardarPedidoOffline(pedidoData)
      })

      // Verificar que se llamó a queueOperation
      await waitFor(() => {
        expect(mockQueueOperation).toHaveBeenCalled()
      })

      const lastCall = mockQueueOperation.mock.calls.at(-1)
      expect(lastCall?.[0]).toBe('CREATE_PEDIDO')
      expect(lastCall?.[1]).toMatchObject({
        clienteId: '456',
        items: [{ productoId: 'p2', cantidad: 1, precioUnitario: 200 }],
        total: 200
      })
    })
  })

  // ===========================================================================
  // SYNC-02: Conflicto de stock al guardar offline
  // ===========================================================================
  describe('SYNC-02: Validación de stock al guardar offline', () => {
    it('debe rechazar pedido si excede stock disponible', async () => {
      const { result } = renderHook(() => useOfflineSync())

      await waitFor(() => {
        expect(result.current.pedidosPendientes).toEqual([])
      })

      // Intentar pedir más stock del disponible
      const pedidoData = {
        clienteId: '123',
        items: [{ productoId: 'p2', cantidad: 10, precioUnitario: 200 }], // stock es 5
        total: 2000
      }

      let saveResult: ReturnType<typeof result.current.guardarPedidoOffline>
      act(() => {
        saveResult = result.current.guardarPedidoOffline(pedidoData, {
          productos: mockProductos,
          validarStock: true
        })
      })

      expect(saveResult!.success).toBe(false)
      expect(saveResult!.error).toBe('Stock insuficiente para algunos productos')
      expect(saveResult!.itemsSinStock).toHaveLength(1)
      expect(saveResult!.itemsSinStock![0]).toMatchObject({
        productoId: 'p2',
        nombre: 'Producto 2',
        solicitado: 10,
        disponible: 5
      })
      expect(result.current.pedidosPendientes).toHaveLength(0)
    })

    it('debe considerar stock reservado por otros pedidos offline', async () => {
      const { result } = renderHook(() => useOfflineSync())

      await waitFor(() => {
        expect(result.current.pedidosPendientes).toEqual([])
      })

      // Primer pedido: usa 3 de 5 unidades disponibles
      act(() => {
        result.current.guardarPedidoOffline(
          {
            clienteId: '1',
            items: [{ productoId: 'p2', cantidad: 3, precioUnitario: 200 }],
            total: 600
          },
          { productos: mockProductos, validarStock: true }
        )
      })

      expect(result.current.pedidosPendientes).toHaveLength(1)

      // Segundo pedido: intenta usar 4 más (solo quedan 2)
      let saveResult: ReturnType<typeof result.current.guardarPedidoOffline>
      act(() => {
        saveResult = result.current.guardarPedidoOffline(
          {
            clienteId: '2',
            items: [{ productoId: 'p2', cantidad: 4, precioUnitario: 200 }],
            total: 800
          },
          { productos: mockProductos, validarStock: true }
        )
      })

      expect(saveResult!.success).toBe(false)
      expect(saveResult!.itemsSinStock![0]).toMatchObject({
        productoId: 'p2',
        solicitado: 4,
        disponible: 2 // 5 - 3 ya reservados
      })
    })

    it('debe incluir snapshot de stock en el pedido guardado', async () => {
      const { result } = renderHook(() => useOfflineSync())

      await waitFor(() => {
        expect(result.current.pedidosPendientes).toEqual([])
      })

      const pedidoData = {
        clienteId: '123',
        items: [{ productoId: 'p1', cantidad: 2, precioUnitario: 100 }],
        total: 200
      }

      let saveResult: ReturnType<typeof result.current.guardarPedidoOffline>
      act(() => {
        saveResult = result.current.guardarPedidoOffline(pedidoData, {
          productos: mockProductos,
          validarStock: true
        })
      })

      expect(saveResult!.pedido?.stockSnapshot).toBeDefined()
      expect(saveResult!.pedido?.stockSnapshot?.['p1']).toMatchObject({
        stockAlMomento: 10,
        reservadoOffline: 0,
        disponible: 10
      })
    })
  })

  // ===========================================================================
  // SYNC-03: Sincronización parcial (algunos pedidos fallan)
  // ===========================================================================
  describe('SYNC-03: Sincronización parcial', () => {
    it('debe continuar sincronizando otros pedidos si uno falla', async () => {
      // Mock getPendingOperations to return 3 pending orders
      const mockPendingOps = [
        { id: 1, type: 'CREATE_PEDIDO', status: 'pending', payload: { clienteId: '1', items: [], total: 100 }, createdAt: new Date() },
        { id: 2, type: 'CREATE_PEDIDO', status: 'pending', payload: { clienteId: '2', items: [], total: 200 }, createdAt: new Date() },
        { id: 3, type: 'CREATE_PEDIDO', status: 'pending', payload: { clienteId: '3', items: [], total: 300 }, createdAt: new Date() }
      ]
      // First call returns all 3 (initial load), second call also returns 3 (sync reads), third returns only failed one (after sync)
      mockGetPendingOperations
        .mockResolvedValueOnce(mockPendingOps) // Initial load
        .mockResolvedValueOnce(mockPendingOps) // Sync reads pending ops
        .mockResolvedValue([mockPendingOps[1]]) // After sync, only failed one remains

      const { result } = renderHook(() => useOfflineSync())

      // Wait for initial load
      await waitFor(() => {
        expect(result.current.pedidosPendientes).toHaveLength(3)
      })

      // Mock: el segundo pedido falla
      mockCrearPedido
        .mockResolvedValueOnce({ id: 1 }) // Éxito
        .mockRejectedValueOnce(new Error('Error de base de datos')) // Falla
        .mockResolvedValueOnce({ id: 3 }) // Éxito

      let syncResult: Awaited<ReturnType<typeof result.current.sincronizarPedidos>>
      await act(async () => {
        syncResult = await result.current.sincronizarPedidos(mockCrearPedido, mockDescontarStock)
      })

      expect(syncResult!.success).toBe(false)
      expect(syncResult!.sincronizados).toBe(2)
      expect(syncResult!.errores).toHaveLength(1)
      expect(syncResult!.errores[0].error).toBe('Error de base de datos')

      // Solo debe quedar el pedido que falló
      expect(result.current.pedidosPendientes).toHaveLength(1)
      expect(result.current.pedidosPendientes[0].clienteId).toBe('2')
    })

    it('debe reportar todos los errores de sincronización', async () => {
      // Mock getPendingOperations to return 2 pending orders
      const mockPendingOps = [
        { id: 1, type: 'CREATE_PEDIDO', status: 'pending', payload: { clienteId: '1', items: [], total: 100 }, createdAt: new Date() },
        { id: 2, type: 'CREATE_PEDIDO', status: 'pending', payload: { clienteId: '2', items: [], total: 200 }, createdAt: new Date() }
      ]
      // First call returns both (initial load), second call also returns both (sync reads), third returns both (both failed)
      mockGetPendingOperations
        .mockResolvedValueOnce(mockPendingOps) // Initial load
        .mockResolvedValueOnce(mockPendingOps) // Sync reads pending ops
        .mockResolvedValue(mockPendingOps) // After sync, both failed so both remain

      const { result } = renderHook(() => useOfflineSync())

      // Wait for initial load
      await waitFor(() => {
        expect(result.current.pedidosPendientes).toHaveLength(2)
      })

      // Ambos fallan con diferentes errores
      mockCrearPedido
        .mockRejectedValueOnce(new Error('Error de red'))
        .mockRejectedValueOnce(new Error('Cliente no existe'))

      let syncResult: Awaited<ReturnType<typeof result.current.sincronizarPedidos>>
      await act(async () => {
        syncResult = await result.current.sincronizarPedidos(mockCrearPedido, mockDescontarStock)
      })

      expect(syncResult!.success).toBe(false)
      expect(syncResult!.sincronizados).toBe(0)
      expect(syncResult!.errores).toHaveLength(2)
      expect(syncResult!.errores[0].error).toBe('Error de red')
      expect(syncResult!.errores[1].error).toBe('Cliente no existe')
    })
  })

  // ===========================================================================
  // SYNC-04: Race condition - doble click en sincronizar
  // ===========================================================================
  describe('SYNC-04: Prevención de race conditions', () => {
    it('debe prevenir sincronización simultánea (doble click)', async () => {
      // Mock a single pending operation
      const mockPendingOps = [
        { id: 1, type: 'CREATE_PEDIDO', status: 'pending', payload: { clienteId: '1', items: [], total: 100 }, createdAt: new Date() }
      ]
      // Return ops for initial load, then for sync reads (multiple times), then empty after sync
      mockGetPendingOperations
        .mockResolvedValueOnce(mockPendingOps) // Initial load
        .mockResolvedValue(mockPendingOps) // Sync reads (may be called multiple times)

      const { result } = renderHook(() => useOfflineSync())

      await waitFor(() => {
        expect(result.current.pedidosPendientes).toHaveLength(1)
      })

      // Mock con delay para simular operación lenta
      mockCrearPedido.mockImplementation(() =>
        new Promise(resolve => setTimeout(() => resolve({ id: 1 }), 100))
      )

      // Intentar sincronizar dos veces simultáneamente
      let results: Array<Awaited<ReturnType<typeof result.current.sincronizarPedidos>>>
      await act(async () => {
        results = await Promise.all([
          result.current.sincronizarPedidos(mockCrearPedido, mockDescontarStock),
          result.current.sincronizarPedidos(mockCrearPedido, mockDescontarStock)
        ])
      })

      // La segunda llamada debe retornar error de sincronización en progreso
      const successfulSync = results!.filter(r => r.sincronizados > 0)
      const blockedSync = results!.filter(r => r.errores.some(e => e.error.includes('en progreso')))

      expect(successfulSync).toHaveLength(1)
      expect(blockedSync).toHaveLength(1)

      // El pedido solo debe crearse una vez
      expect(mockCrearPedido).toHaveBeenCalledTimes(1)
    })

    it('debe permitir sincronizar después de que termine la sincronización anterior', async () => {
      // First sync: 1 pending operation
      const mockOp1 = { id: 1, type: 'CREATE_PEDIDO', status: 'pending', payload: { clienteId: '1', items: [], total: 100 }, createdAt: new Date() }
      // Initial load returns op1, first sync returns op1, after sync returns empty
      mockGetPendingOperations
        .mockResolvedValueOnce([mockOp1]) // Initial load
        .mockResolvedValueOnce([mockOp1]) // First sync reads
        .mockResolvedValueOnce([]) // After first sync

      const { result } = renderHook(() => useOfflineSync())

      await waitFor(() => {
        expect(result.current.pedidosPendientes).toHaveLength(1)
      })

      // Primera sincronización
      await act(async () => {
        await result.current.sincronizarPedidos(mockCrearPedido, mockDescontarStock)
      })

      expect(result.current.pedidosPendientes).toHaveLength(0)
      expect(mockCrearPedido).toHaveBeenCalledTimes(1)

      // Second sync: new pending operation
      const mockOp2 = { id: 2, type: 'CREATE_PEDIDO', status: 'pending', payload: { clienteId: '2', items: [], total: 200 }, createdAt: new Date() }
      // For second sync: return op2 for sync, then empty after sync
      mockGetPendingOperations
        .mockResolvedValueOnce([mockOp2]) // Second sync reads
        .mockResolvedValue([]) // After second sync

      // Guardar segundo pedido (updates local state)
      act(() => {
        result.current.guardarPedidoOffline({ clienteId: '2', items: [], total: 200 })
      })

      // Segunda sincronización (debe funcionar)
      await act(async () => {
        await result.current.sincronizarPedidos(mockCrearPedido, mockDescontarStock)
      })

      expect(result.current.pedidosPendientes).toHaveLength(0)
      expect(mockCrearPedido).toHaveBeenCalledTimes(2)
    })
  })

  // ===========================================================================
  // SYNC-05: Sincronización de mermas
  // ===========================================================================
  describe('SYNC-05: Sincronización de mermas offline', () => {
    it('debe guardar y sincronizar mermas offline', async () => {
      // Start with no pending operations
      mockGetPendingOperations.mockResolvedValue([])

      const { result } = renderHook(() => useOfflineSync())

      await waitFor(() => {
        expect(result.current.mermasPendientes).toEqual([])
      })

      // Guardar merma offline (updates local state)
      const mermaData = {
        producto_id: 'p1',
        cantidad: 2,
        tipo_merma: 'vencimiento' as const,
        motivo: 'Producto vencido'
      }

      act(() => {
        result.current.guardarMermaOffline(mermaData)
      })

      expect(result.current.mermasPendientes).toHaveLength(1)
      expect(result.current.mermasPendientes[0]).toMatchObject({
        producto_id: 'p1',
        cantidad: 2,
        tipo_merma: 'vencimiento'
      })

      // Mock pending merma for sync
      const mockMermaOp = {
        id: 1,
        type: 'CREATE_MERMA',
        status: 'pending',
        payload: mermaData,
        createdAt: new Date()
      }
      mockGetPendingOperations.mockResolvedValue([mockMermaOp])

      // Sincronizar mermas
      let syncResult: Awaited<ReturnType<typeof result.current.sincronizarMermas>>
      await act(async () => {
        syncResult = await result.current.sincronizarMermas(mockRegistrarMerma)
        // Update mock to return empty after sync
        mockGetPendingOperations.mockResolvedValue([])
      })

      expect(syncResult!.success).toBe(true)
      expect(syncResult!.sincronizados).toBe(1)
      expect(mockRegistrarMerma).toHaveBeenCalledTimes(1)
    })

    it('debe manejar errores de sincronización de mermas', async () => {
      // Start with a pending merma
      const mockMermaOp = {
        id: 1,
        type: 'CREATE_MERMA',
        status: 'pending',
        payload: { producto_id: 'p1', cantidad: 2, tipo_merma: 'rotura', motivo: 'Producto roto' },
        createdAt: new Date()
      }
      mockGetPendingOperations.mockResolvedValue([mockMermaOp])

      const { result } = renderHook(() => useOfflineSync())

      await waitFor(() => {
        expect(result.current.mermasPendientes).toHaveLength(1)
      })

      // Mock falla
      mockRegistrarMerma.mockRejectedValueOnce(new Error('Error al registrar merma'))

      let syncResult: Awaited<ReturnType<typeof result.current.sincronizarMermas>>
      await act(async () => {
        syncResult = await result.current.sincronizarMermas(mockRegistrarMerma)
      })

      expect(syncResult!.success).toBe(false)
      expect(syncResult!.errores).toHaveLength(1)
    })
  })

  // ===========================================================================
  // SYNC-06: Contador de pendientes
  // ===========================================================================
  describe('SYNC-06: Contador de pendientes', () => {
    it('debe calcular correctamente el total de pendientes', async () => {
      const { result } = renderHook(() => useOfflineSync())

      await waitFor(() => {
        expect(result.current.cantidadPendientes).toBe(0)
      })

      // Agregar pedidos
      act(() => {
        result.current.guardarPedidoOffline({ clienteId: '1', items: [], total: 100 })
        result.current.guardarPedidoOffline({ clienteId: '2', items: [], total: 200 })
      })

      expect(result.current.cantidadPendientes).toBe(2)

      // Agregar mermas
      act(() => {
        result.current.guardarMermaOffline({
          producto_id: 'p1',
          cantidad: 1,
          tipo_merma: 'robo' as const,
          motivo: 'Faltante'
        })
      })

      expect(result.current.cantidadPendientes).toBe(3)
    })
  })

  // ===========================================================================
  // Estado de conexión
  // ===========================================================================
  describe('Detección de estado de conexión', () => {
    it('debe detectar eventos online/offline', async () => {
      const { result } = renderHook(() => useOfflineSync())

      expect(result.current.isOnline).toBe(true)

      act(() => {
        Object.defineProperty(navigator, 'onLine', { value: false, configurable: true })
        window.dispatchEvent(new Event('offline'))
      })

      expect(result.current.isOnline).toBe(false)

      act(() => {
        Object.defineProperty(navigator, 'onLine', { value: true, configurable: true })
        window.dispatchEvent(new Event('online'))
      })

      expect(result.current.isOnline).toBe(true)
    })

    it('no debe sincronizar si está offline', async () => {
      // Mock a pending operation
      const mockPendingOp = {
        id: 1,
        type: 'CREATE_PEDIDO',
        status: 'pending',
        payload: { clienteId: '1', items: [], total: 100 },
        createdAt: new Date()
      }
      mockGetPendingOperations.mockResolvedValue([mockPendingOp])

      const { result } = renderHook(() => useOfflineSync())

      await waitFor(() => {
        expect(result.current.pedidosPendientes).toHaveLength(1)
      })

      // Simular offline
      act(() => {
        Object.defineProperty(navigator, 'onLine', { value: false, configurable: true })
        window.dispatchEvent(new Event('offline'))
      })

      // Intentar sincronizar (debe retornar sin hacer nada)
      let syncResult: Awaited<ReturnType<typeof result.current.sincronizarPedidos>>
      await act(async () => {
        syncResult = await result.current.sincronizarPedidos(mockCrearPedido, mockDescontarStock)
      })

      expect(syncResult!.sincronizados).toBe(0)
      expect(mockCrearPedido).not.toHaveBeenCalled()
      expect(result.current.pedidosPendientes).toHaveLength(1)
    })
  })

  // ===========================================================================
  // Limpieza de pedidos
  // ===========================================================================
  describe('Limpieza de datos offline', () => {
    it('debe limpiar todos los pedidos offline', async () => {
      const { result } = renderHook(() => useOfflineSync())

      await waitFor(() => {
        expect(result.current.pedidosPendientes).toEqual([])
      })

      // Agregar pedidos
      act(() => {
        result.current.guardarPedidoOffline({ clienteId: '1', items: [], total: 100 })
        result.current.guardarPedidoOffline({ clienteId: '2', items: [], total: 200 })
      })

      expect(result.current.pedidosPendientes).toHaveLength(2)

      // Limpiar
      act(() => {
        result.current.limpiarPedidosOffline()
      })

      expect(result.current.pedidosPendientes).toHaveLength(0)
      // Now uses cleanupOldOperations instead of removeSecureItem
      await waitFor(() => {
        expect(mockCleanupOldOperations).toHaveBeenCalledWith(0)
      })
    })

    it('debe poder eliminar un pedido específico', async () => {
      const { result } = renderHook(() => useOfflineSync())

      await waitFor(() => {
        expect(result.current.pedidosPendientes).toEqual([])
      })

      // Guardar pedidos
      let pedido1: PedidoOffline | undefined
      let pedido2: PedidoOffline | undefined

      act(() => {
        const result1 = result.current.guardarPedidoOffline({ clienteId: '1', items: [], total: 100 })
        const result2 = result.current.guardarPedidoOffline({ clienteId: '2', items: [], total: 200 })
        pedido1 = result1.pedido
        pedido2 = result2.pedido
      })

      expect(result.current.pedidosPendientes).toHaveLength(2)

      // Eliminar solo el primero
      act(() => {
        result.current.eliminarPedidoOffline(pedido1!.offlineId)
      })

      expect(result.current.pedidosPendientes).toHaveLength(1)
      expect(result.current.pedidosPendientes[0].offlineId).toBe(pedido2!.offlineId)
    })
  })
})

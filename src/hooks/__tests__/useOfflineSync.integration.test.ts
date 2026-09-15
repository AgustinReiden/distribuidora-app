/**
 * Tests de Integración para useOfflineSync
 *
 * Escenarios críticos:
 * - SYNC-01: Guardar pedido offline → reconectar → sincronizar exitosamente
 * - SYNC-02: Conflicto de stock: pedido offline con stock insuficiente al sincronizar
 * - SYNC-03: Sincronización parcial: algunos pedidos fallan
 * - SYNC-04: Race condition: doble click en sincronizar
 * - SYNC-06: Migración de datos legacy
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'
import { useOfflineSync, claveIdempotencia } from '../useOfflineSync'
import { useSyncManager } from '../useSyncManager'
import type { PendingOperation } from '../../lib/offlineDb'
import type { PedidoOffline, ProductoDB } from '../../types'

// Mock de offlineDb (ahora useOfflineSync usa IndexedDB via offlineDb)
const mockQueueOperation = vi.fn().mockResolvedValue(1)
const mockGetPendingOperations = vi.fn().mockResolvedValue([])
const mockMarkAsCompleted = vi.fn().mockResolvedValue(undefined)
const mockMarkAsFailed = vi.fn().mockResolvedValue(undefined)
const mockCleanupOldOperations = vi.fn().mockResolvedValue(0)
const mockDeletePendingOperation = vi.fn().mockResolvedValue(undefined)
const mockDeletePendingOperations = vi.fn().mockResolvedValue(0)

vi.mock('../../lib/offlineDb', () => ({
  queueOperation: (...args: unknown[]) => mockQueueOperation(...args),
  getPendingOperations: (...args: unknown[]) => mockGetPendingOperations(...args),
  markAsCompleted: (...args: unknown[]) => mockMarkAsCompleted(...args),
  markAsFailed: (...args: unknown[]) => mockMarkAsFailed(...args),
  cleanupOldOperations: (...args: unknown[]) => mockCleanupOldOperations(...args),
  deletePendingOperation: (...args: unknown[]) => mockDeletePendingOperation(...args),
  deletePendingOperations: (...args: unknown[]) => mockDeletePendingOperations(...args),
}))

// Mock del cliente Supabase y el contexto de sucursal — necesario porque
// useOfflineSync ahora importa setSucursalHeader de ../../lib/supabase y
// useSucursal de ../../contexts/SucursalContext para etiquetar cada op con
// el sucursal_id activo (ver commit 9181a66 / Task 5 multi-tenant).
// `auth.refreshSession` lo usa el replay cuando el error huele a JWT vencido
// (ver utils/sesionVencida), que es lo típico al reconectar.
const mockRefreshSession = vi.fn().mockResolvedValue({ data: { session: { user: { id: 'user-A' } } }, error: null })

vi.mock('../../lib/supabase', () => ({
  supabase: {
    from: vi.fn(),
    rpc: vi.fn(),
    rest: { headers: {} },
    auth: { refreshSession: (...args: unknown[]) => mockRefreshSession(...args) },
  },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))

// Mutable para poder cambiar de usuario/sucursal en los tests de teléfono
// compartido. `useSucursal` lo lee en cada render, no al crear el mock.
const sesionActiva = vi.hoisted(() => ({ userId: 'user-A' as string | null, sucursalId: 1 as number | null }))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({
    userId: sesionActiva.userId,
    currentSucursalId: sesionActiva.sucursalId,
    sucursales: [{ id: 1, nombre: 'Test', rol: 'admin' }],
    loading: false,
    switchSucursal: vi.fn(),
  }),
}))

describe('useOfflineSync Integration Tests', () => {
  // Productos de prueba
  const mockProductos: ProductoDB[] = [
    { id: 'p1', nombre: 'Producto 1', stock: 10, precio: 100, activo: true } as ProductoDB,
    { id: 'p2', nombre: 'Producto 2', stock: 5, precio: 200, activo: true } as ProductoDB,
    { id: 'p3', nombre: 'Producto 3', stock: 0, precio: 300, activo: true } as ProductoDB
  ]

  // Mock de funciones de API
  const mockCrearPedido = vi.fn()

  beforeEach(() => {
    vi.clearAllMocks()
    sesionActiva.userId = 'user-A'
    sesionActiva.sucursalId = 1

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
    mockDeletePendingOperation.mockResolvedValue(undefined)
    mockDeletePendingOperations.mockResolvedValue(0)
    mockRefreshSession.mockResolvedValue({ data: { session: { user: { id: 'user-A' } } }, error: null })

    // Reset mocks de API
    mockCrearPedido.mockResolvedValue({ id: 1, success: true })
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

      let saveResult: Awaited<ReturnType<typeof result.current.guardarPedidoOffline>>
      await act(async () => {
        saveResult = await result.current.guardarPedidoOffline(pedidoData, {
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
        status: 'pending', sucursalId: 1,
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
        syncResult = await result.current.sincronizarPedidos(mockCrearPedido)
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

      await act(async () => {
        await result.current.guardarPedidoOffline(pedidoData)
      })

      // Verificar que se llamó a queueOperation
      expect(mockQueueOperation).toHaveBeenCalled()

      const calls = mockQueueOperation.mock.calls
      const lastCall = calls[calls.length - 1]
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

      let saveResult: Awaited<ReturnType<typeof result.current.guardarPedidoOffline>>
      await act(async () => {
        saveResult = await result.current.guardarPedidoOffline(pedidoData, {
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
      await act(async () => {
        await result.current.guardarPedidoOffline(
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
      let saveResult: Awaited<ReturnType<typeof result.current.guardarPedidoOffline>>
      await act(async () => {
        saveResult = await result.current.guardarPedidoOffline(
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

      let saveResult: Awaited<ReturnType<typeof result.current.guardarPedidoOffline>>
      await act(async () => {
        saveResult = await result.current.guardarPedidoOffline(pedidoData, {
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
        { id: 1, type: 'CREATE_PEDIDO', status: 'pending', sucursalId: 1, payload: { clienteId: '1', items: [], total: 100 }, createdAt: new Date() },
        { id: 2, type: 'CREATE_PEDIDO', status: 'pending', sucursalId: 1, payload: { clienteId: '2', items: [], total: 200 }, createdAt: new Date() },
        { id: 3, type: 'CREATE_PEDIDO', status: 'pending', sucursalId: 1, payload: { clienteId: '3', items: [], total: 300 }, createdAt: new Date() }
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
        syncResult = await result.current.sincronizarPedidos(mockCrearPedido)
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
        { id: 1, type: 'CREATE_PEDIDO', status: 'pending', sucursalId: 1, payload: { clienteId: '1', items: [], total: 100 }, createdAt: new Date() },
        { id: 2, type: 'CREATE_PEDIDO', status: 'pending', sucursalId: 1, payload: { clienteId: '2', items: [], total: 200 }, createdAt: new Date() }
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
        syncResult = await result.current.sincronizarPedidos(mockCrearPedido)
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
        { id: 1, type: 'CREATE_PEDIDO', status: 'pending', sucursalId: 1, payload: { clienteId: '1', items: [], total: 100 }, createdAt: new Date() }
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
          result.current.sincronizarPedidos(mockCrearPedido),
          result.current.sincronizarPedidos(mockCrearPedido)
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
      const mockOp1 = { id: 1, type: 'CREATE_PEDIDO', status: 'pending', sucursalId: 1, payload: { clienteId: '1', items: [], total: 100 }, createdAt: new Date() }
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
        await result.current.sincronizarPedidos(mockCrearPedido)
      })

      expect(result.current.pedidosPendientes).toHaveLength(0)
      expect(mockCrearPedido).toHaveBeenCalledTimes(1)

      // Second sync: new pending operation
      const mockOp2 = { id: 2, type: 'CREATE_PEDIDO', status: 'pending', sucursalId: 1, payload: { clienteId: '2', items: [], total: 200 }, createdAt: new Date() }
      // For second sync: return op2 for sync, then empty after sync
      mockGetPendingOperations
        .mockResolvedValueOnce([mockOp2]) // Second sync reads
        .mockResolvedValue([]) // After second sync

      // Guardar segundo pedido (updates local state)
      await act(async () => {
        await result.current.guardarPedidoOffline({ clienteId: '2', items: [], total: 200 })
      })

      // Segunda sincronización (debe funcionar)
      await act(async () => {
        await result.current.sincronizarPedidos(mockCrearPedido)
      })

      expect(result.current.pedidosPendientes).toHaveLength(0)
      expect(mockCrearPedido).toHaveBeenCalledTimes(2)
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
      await act(async () => {
        await result.current.guardarPedidoOffline({ clienteId: '1', items: [], total: 100 })
        await result.current.guardarPedidoOffline({ clienteId: '2', items: [], total: 200 })
      })

      expect(result.current.cantidadPendientes).toBe(2)
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
        status: 'pending', sucursalId: 1,
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
        syncResult = await result.current.sincronizarPedidos(mockCrearPedido)
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
      await act(async () => {
        await result.current.guardarPedidoOffline({ clienteId: '1', items: [], total: 100 })
        await result.current.guardarPedidoOffline({ clienteId: '2', items: [], total: 200 })
      })

      expect(result.current.pedidosPendientes).toHaveLength(2)

      // limpiarPedidosOffline relee IndexedDB (mismo alcance que el panel) y
      // borra lo que encuentra ahí, no cleanupOldOperations(0) -- eso sólo
      // borraba operaciones 'completed', así que lo pendiente y lo fallido
      // nunca se iba de la cola.
      const opsEnCola = [
        { id: 10, type: 'CREATE_PEDIDO', status: 'pending', payload: { n: 1 }, createdAt: new Date() },
        { id: 11, type: 'CREATE_PEDIDO', status: 'pending', payload: { n: 2 }, createdAt: new Date() },
      ]
      mockGetPendingOperations.mockResolvedValueOnce(opsEnCola)

      // Limpiar
      act(() => {
        result.current.limpiarPedidosOffline()
      })

      expect(result.current.pedidosPendientes).toHaveLength(0)
      expect(mockCleanupOldOperations).not.toHaveBeenCalledWith(0)
      await waitFor(() => {
        expect(mockDeletePendingOperations).toHaveBeenCalledWith([10, 11])
      })
    })

    it('debe poder eliminar un pedido específico, borrándolo de IndexedDB (no marcándolo failed)', async () => {
      // offlineId con forma `op_<id>`, como lo entrega la cola real (ver
      // operationToPedidoOffline) -- no el `offline_<timestamp>_<rand>`
      // temporal que devuelve guardarPedidoOffline antes de releer. El test
      // viejo eliminaba por ese id temporal, para el que el regex de
      // eliminarPedidoOffline nunca matchea: la llamada a IndexedDB quedaba
      // sin ejercitar y el test sólo veía que React "olvidó" el pedido.
      const opPedido1 = { id: 101, type: 'CREATE_PEDIDO', status: 'pending', payload: { clienteId: '1', items: [], total: 100 }, createdAt: new Date() }
      const opPedido2 = { id: 102, type: 'CREATE_PEDIDO', status: 'pending', payload: { clienteId: '2', items: [], total: 200 }, createdAt: new Date() }
      mockGetPendingOperations.mockResolvedValue([opPedido1, opPedido2])

      const { result } = renderHook(() => useOfflineSync())

      await waitFor(() => {
        expect(result.current.pedidosPendientes).toHaveLength(2)
      })

      const pedido1 = result.current.pedidosPendientes.find(p => p.offlineId === 'op_101')!
      const pedido2 = result.current.pedidosPendientes.find(p => p.offlineId === 'op_102')!
      expect(pedido1).toBeDefined()
      expect(pedido2).toBeDefined()

      // Eliminar solo el primero
      act(() => {
        result.current.eliminarPedidoOffline(pedido1.offlineId)
      })

      expect(result.current.pedidosPendientes).toHaveLength(1)
      expect(result.current.pedidosPendientes[0].offlineId).toBe(pedido2.offlineId)

      // La eliminación real es un borrado en IndexedDB, no un markAsFailed
      // (eso lo dejaba en la cola, visible en el panel de fallidas).
      await waitFor(() => {
        expect(mockDeletePendingOperation).toHaveBeenCalledWith(101)
      })
      expect(mockMarkAsFailed).not.toHaveBeenCalled()
    })

    /**
     * H57. guardarPedidoOffline dejaba en estado el id temporal
     * (`offline_<ts>_<rand>`) hasta el próximo loadPendingOperations, y la
     * instancia que encoló no se relee sola (ver "la emisora ya se actualizo
     * sola" en el listener de OFFLINE_QUEUE_CHANGED). Borrar ese pedido en la
     * MISMA sesión llamaba a eliminarPedidoOffline con el id temporal, que el
     * regex `/^op_(\d+)$/` nunca matchea: el pedido desaparecía de la UI pero
     * quedaba vivo en IndexedDB y se sincronizaba igual. El fix hace que
     * guardarPedidoOffline reemplace el id temporal por el real (`op_<id>`)
     * apenas queueOperation resuelve, así que lo que ve la UI ya es borrable.
     */
    it('guardar y borrar un pedido en la misma sesión lo saca también de la cola', async () => {
      mockQueueOperation.mockResolvedValueOnce(55)

      const { result } = renderHook(() => useOfflineSync())

      await waitFor(() => {
        expect(result.current.pedidosPendientes).toEqual([])
      })

      let saveResult: Awaited<ReturnType<typeof result.current.guardarPedidoOffline>>
      await act(async () => {
        saveResult = await result.current.guardarPedidoOffline({ clienteId: '1', items: [], total: 100 })
      })

      // El id que queda en pantalla ya es el real de la cola, no el temporal.
      expect(saveResult!.pedido!.offlineId).toBe('op_55')
      expect(result.current.pedidosPendientes[0].offlineId).toBe('op_55')

      act(() => {
        result.current.eliminarPedidoOffline(saveResult!.pedido!.offlineId)
      })

      expect(result.current.pedidosPendientes).toHaveLength(0)
      // El borrado le llega de verdad a IndexedDB con el id real de Dexie, no
      // se queda en un filtro de estado que la deja viva en la cola.
      await waitFor(() => {
        expect(mockDeletePendingOperation).toHaveBeenCalledWith(55)
      })
    })
  })

  /**
   * El replay pasaba `undefined` en cuatro posiciones seguidas para llegar al
   * offlineId, y ahi se perdian el tipo de factura, el desglose fiscal y el
   * preventista. Un pedido cargado sin señal entraba DISTINTO al mismo pedido
   * cargado con señal: fechado el dia del replay, en ZZ, sin neto/IVA y
   * acreditado a quien sincronizara.
   */
  describe('El pedido encolado entra igual que uno online', () => {
    const pedidoCompleto = {
      clienteId: '123',
      items: [
        { productoId: 'p1', cantidad: 2, precioUnitario: 100, neto_unitario: 82.6, iva_unitario: 17.4, porcentaje_iva: 21 },
        { productoId: 'p2', cantidad: 1, precioUnitario: 0, esBonificacion: true, promocionId: 'promo-9' },
      ],
      total: 200,
      usuarioId: 'user1',
      fecha: '2026-08-18',
      fechaEntregaProgramada: '2026-08-19',
      tipoFactura: 'FC' as const,
      totalNeto: 165.2,
      totalIva: 34.8,
      preventistaId: 'preventista-7',
      origenes: [{ producto_id: 'p1', origen: 'mayorista' }],
    }

    const opConPedidoCompleto = {
      id: 42,
      type: 'CREATE_PEDIDO',
      status: 'pending',
      sucursalId: 1,
      payload: pedidoCompleto,
      createdAt: new Date(),
    }

    it('no pierde factura, desglose fiscal, fechas ni preventista', async () => {
      mockGetPendingOperations.mockResolvedValue([opConPedidoCompleto])
      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))

      await act(async () => { await result.current.sincronizarPedidos(mockCrearPedido) })

      expect(mockCrearPedido).toHaveBeenCalledTimes(1)
      expect(mockCrearPedido.mock.calls[0][0]).toMatchObject({
        clienteId: '123',
        total: 200,
        fecha: '2026-08-18',
        fechaEntregaProgramada: '2026-08-19',
        tipoFactura: 'FC',
        totalNeto: 165.2,
        totalIva: 34.8,
        preventistaId: 'preventista-7',
        origenes: [{ producto_id: 'p1', origen: 'mayorista' }],
      })
    })

    it('conserva la bonificacion como bonificacion, no como item cobrado', async () => {
      mockGetPendingOperations.mockResolvedValue([opConPedidoCompleto])
      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))

      await act(async () => { await result.current.sincronizarPedidos(mockCrearPedido) })

      const items = mockCrearPedido.mock.calls[0][0].items
      expect(items[1]).toMatchObject({ productoId: 'p2', esBonificacion: true, promocionId: 'promo-9' })
      expect(items[0]).toMatchObject({ neto_unitario: 82.6, iva_unitario: 17.4, porcentaje_iva: 21 })
    })

    it('usa un offlineId estable para que el reintento no duplique', async () => {
      // Estable, pero YA NO `op_42`: ese era el autoincrement de Dexie. Ver el
      // bloque IDEM-01.
      mockGetPendingOperations.mockResolvedValue([opConPedidoCompleto])
      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))

      await act(async () => { await result.current.sincronizarPedidos(mockCrearPedido) })
      await act(async () => { await result.current.sincronizarPedidos(mockCrearPedido) })

      const primera = mockCrearPedido.mock.calls[0][0].offlineId
      expect(primera).toBeTruthy()
      expect(mockCrearPedido.mock.calls[1][0].offlineId).toBe(primera)
    })

    // Sin red no se registra el cobro: el replay no inserta en `pagos`, asi que
    // un 'pagado' encolado entraria impago y el chofer se lo cobraria de nuevo
    // al cliente. Se fuerza el unico estado que no miente.
    it('fuerza estadoPago pendiente aunque la cola traiga otra cosa', async () => {
      mockGetPendingOperations.mockResolvedValue([
        { ...opConPedidoCompleto, payload: { ...pedidoCompleto, estadoPago: 'pagado', montoPagado: 200 } },
      ])
      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))

      await act(async () => { await result.current.sincronizarPedidos(mockCrearPedido) })

      expect(mockCrearPedido.mock.calls[0][0].estadoPago).toBe('pendiente')
    })
  })

  // ===========================================================================
  // IDEM-01: la clave de idempotencia tiene que ser única en el MUNDO
  // ===========================================================================
  /**
   * EL INCIDENTE. El replay mandaba `op_<op.id>`, donde `op.id` es el
   * autoincrement de Dexie: arranca en 1 en cada instalación.
   * `crear_pedido_idempotente` (mig 071) busca `offline_id` en TODA la tabla
   * `pedidos` — índice único global, SECURITY DEFINER. O sea que el primer
   * pedido offline de cualquier teléfono era `op_1`: el segundo teléfono que
   * sincronizaba recibía el pedido AJENO con `idempotente: true`, lo marcaba
   * como sincronizado, avisaba "1 pedido(s) sincronizado(s)"... y su pedido no
   * existía en ningún lado. Lo mismo al purgar IndexedDB.
   */
  describe('IDEM-01: clave de idempotencia por operación, no por autoincrement', () => {
    it('el pedido encolado se lleva su propio UUID', async () => {
      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toEqual([]))

      await act(async () => {
        await result.current.guardarPedidoOffline({ clienteId: '1', items: [], total: 100 })
        await result.current.guardarPedidoOffline({ clienteId: '2', items: [], total: 200 })
      })

      const uuids = mockQueueOperation.mock.calls.map(c => (c[1] as { offlineUuid?: string }).offlineUuid)
      expect(uuids).toHaveLength(2)
      uuids.forEach(uuid =>
        expect(uuid).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i))
      expect(uuids[0]).not.toBe(uuids[1])
    })

    it('el replay manda el UUID del payload, no el id de Dexie', async () => {
      mockGetPendingOperations.mockResolvedValue([{
        id: 1,
        type: 'CREATE_PEDIDO',
        status: 'pending',
        sucursalId: 1,
        userId: 'user-A',
        payload: { clienteId: '1', items: [], total: 100, offlineUuid: '11111111-2222-4333-8444-555555555555' },
        createdAt: new Date(),
      }])

      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))
      await act(async () => { await result.current.sincronizarPedidos(mockCrearPedido) })

      expect(mockCrearPedido.mock.calls[0][0].offlineId).toBe('11111111-2222-4333-8444-555555555555')
    })

    it('dos instalaciones con op.id = 1 no comparten clave', () => {
      // Operaciones viejas, encoladas antes de que la cola acuñara UUID: su
      // única identidad es el autoincrement, que en las dos vale 1.
      const enTelefonoDeA = { id: 1, userId: 'user-A', payload: {} } as unknown as PendingOperation
      const enTelefonoDeB = { id: 1, userId: 'user-B', payload: {} } as unknown as PendingOperation

      const claveA = claveIdempotencia(enTelefonoDeA)
      const claveB = claveIdempotencia(enTelefonoDeB)

      expect(claveA).not.toBe(claveB)
      expect(claveA).not.toBe('op_1')
      expect(claveB).not.toBe('op_1')
    })

    it('sin usuario anotado cae en la identidad de la instalación, y sigue siendo estable', () => {
      const sinDueno = { id: 1, payload: {} } as unknown as PendingOperation

      const primera = claveIdempotencia(sinDueno)
      expect(primera).not.toBe('op_1')
      // Estable: si cambiara entre reintentos, cada uno crearía un pedido nuevo.
      expect(claveIdempotencia(sinDueno)).toBe(primera)
    })
  })

  // ===========================================================================
  // IDEM-02: "ya existía" no quiere decir "es tuyo"
  // ===========================================================================
  describe('IDEM-02: segunda defensa ante una respuesta idempotente', () => {
    const opDeEsteTelefono = {
      id: 7,
      type: 'CREATE_PEDIDO',
      status: 'pending',
      sucursalId: 1,
      userId: 'user-A',
      payload: { clienteId: '123', items: [], total: 200, offlineUuid: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' },
      createdAt: new Date(),
    }

    it('no marca como sincronizado un pedido que es de otro', async () => {
      mockGetPendingOperations.mockResolvedValue([opDeEsteTelefono])
      mockCrearPedido.mockResolvedValue({ id: '9001', idempotente: true, clienteId: '999', total: 111 })

      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))

      let syncResult: Awaited<ReturnType<typeof result.current.sincronizarPedidos>>
      await act(async () => { syncResult = await result.current.sincronizarPedidos(mockCrearPedido) })

      expect(mockMarkAsCompleted).not.toHaveBeenCalled()
      expect(syncResult!.sincronizados).toBe(0)
      expect(syncResult!.errores).toHaveLength(1)
      // Reintentar no lo va a arreglar: la clave la tiene otro pedido.
      expect(mockMarkAsFailed).toHaveBeenCalledWith(
        7,
        expect.stringContaining('ya la tiene otro pedido'),
        { terminal: true },
      )
    })

    it('sí lo marca cuando el pedido que ya existía es este', async () => {
      // Reintento legítimo: la primera request llegó y se perdió la respuesta.
      mockGetPendingOperations.mockResolvedValue([opDeEsteTelefono])
      mockCrearPedido.mockResolvedValue({ id: '9001', idempotente: true, clienteId: '123', total: 200 })

      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))

      let syncResult: Awaited<ReturnType<typeof result.current.sincronizarPedidos>>
      await act(async () => { syncResult = await result.current.sincronizarPedidos(mockCrearPedido) })

      expect(mockMarkAsCompleted).toHaveBeenCalledWith(7)
      expect(syncResult!.sincronizados).toBe(1)
    })

    it('si no se pudo verificar, no lo da por sincronizado pero deja reintentar', async () => {
      mockGetPendingOperations.mockResolvedValue([opDeEsteTelefono])
      mockCrearPedido.mockResolvedValue({ id: '9001', idempotente: true, clienteId: null, total: null })

      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))
      await act(async () => { await result.current.sincronizarPedidos(mockCrearPedido) })

      expect(mockMarkAsCompleted).not.toHaveBeenCalled()
      expect(mockMarkAsFailed).toHaveBeenCalledWith(
        7,
        expect.stringContaining('no se pudo leer'),
        { terminal: false },
      )
    })
  })

  // ===========================================================================
  // SYNC-08: un blip de red no puede quemar los 5 reintentos
  // ===========================================================================
  describe('SYNC-08: reintentos ante fallo de red', () => {
    const opPendiente = {
      id: 3,
      type: 'CREATE_PEDIDO',
      status: 'pending',
      sucursalId: 1,
      userId: 'user-A',
      payload: { clienteId: '1', items: [], total: 100, offlineUuid: 'ffffffff-1111-4222-8333-444444444444' },
      createdAt: new Date(),
    }

    it('un fallo de red gasta un solo reintento de la cola', async () => {
      mockGetPendingOperations.mockResolvedValue([opPendiente])
      // Así vuelve un fallo de red de supabase-js: objeto plano, code vacío.
      mockCrearPedido.mockRejectedValue({ message: 'TypeError: Failed to fetch', code: '' })

      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))
      await act(async () => { await result.current.sincronizarPedidos(mockCrearPedido) })

      // El backoff reintenta adentro (la RPC es idempotente por offlineId)...
      expect(mockCrearPedido.mock.calls.length).toBeGreaterThan(1)
      // ...y la operación consume UN solo intento, no cinco.
      expect(mockMarkAsFailed).toHaveBeenCalledTimes(1)
    })

    it('la sesión vencida se renueva y se reintenta sin gastar reintentos', async () => {
      mockGetPendingOperations.mockResolvedValue([opPendiente])
      mockCrearPedido
        .mockRejectedValueOnce(new Error('No se pudo determinar la sucursal activa'))
        .mockResolvedValueOnce({ id: '1' })

      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))

      let syncResult: Awaited<ReturnType<typeof result.current.sincronizarPedidos>>
      await act(async () => { syncResult = await result.current.sincronizarPedidos(mockCrearPedido) })

      expect(mockRefreshSession).toHaveBeenCalledTimes(1)
      expect(syncResult!.sincronizados).toBe(1)
      expect(mockMarkAsFailed).not.toHaveBeenCalled()
      // El reintento usa la MISMA clave: si no, crearía un pedido nuevo.
      expect(mockCrearPedido.mock.calls[1][0].offlineId).toBe(mockCrearPedido.mock.calls[0][0].offlineId)
    })

    it('el auto-sync no vuelve a intentar en cada render', async () => {
      // EL BUG: el efecto dependía de `ejecutarSincronizacion`, que dependía de
      // `notify`, y el value de NotificationContext se recreaba en cada render.
      // Cada notify.error del propio sync lo re-disparaba: los 5 reintentos se
      // consumían en segundos y el pedido quedaba en `failed`, fuera de la cola.
      const sincronizarPedidos = vi.fn().mockResolvedValue({
        sincronizados: 0,
        errores: [{ error: 'Failed to fetch' }],
      })
      const deps = {
        isOnline: true,
        pedidosPendientes: [{ offlineId: 'op_1' }],
        sincronizando: false,
        sincronizarPedidos,
        crearPedido: vi.fn(),
        refetchPedidos: vi.fn().mockResolvedValue(undefined),
        refetchProductos: vi.fn().mockResolvedValue(undefined),
        refetchMetricas: vi.fn().mockResolvedValue(undefined),
      }
      // Un `notify` nuevo en cada render, que es exactamente lo que hacía el
      // provider sin useMemo.
      const nuevoNotify = () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn(), info: vi.fn() })

      const { rerender } = renderHook(
        (props: { notify: ReturnType<typeof nuevoNotify> }) =>
          useSyncManager({ ...deps, ...props } as unknown as Parameters<typeof useSyncManager>[0]),
        { initialProps: { notify: nuevoNotify() } },
      )

      await waitFor(() => expect(sincronizarPedidos).toHaveBeenCalledTimes(1))

      for (let i = 0; i < 5; i++) {
        await act(async () => { rerender({ notify: nuevoNotify() }) })
      }

      expect(sincronizarPedidos).toHaveBeenCalledTimes(1)
    })
  })

  // ===========================================================================
  // SYNC-09: teléfono compartido
  // ===========================================================================
  /**
   * IndexedDB es del teléfono, no de la sesión, y el logout no la borra a
   * propósito: una cola borrada es un pedido perdido. Lo que corresponde es que
   * la cola del otro no se vea ni se replaye hasta que su dueño vuelva a entrar.
   *
   * El filtro de verdad vive en `getPendingOperations` y se prueba contra Dexie
   * en src/lib/offlineDb.test.ts; acá se fija la otra mitad, que es que el hook
   * diga de quién es la sesión.
   */
  describe('SYNC-09: la cola es del usuario que está adentro', () => {
    const colaDelTelefono = [
      { id: 1, type: 'CREATE_PEDIDO', status: 'pending', sucursalId: 1, userId: 'user-A', payload: { clienteId: 'de A', items: [], total: 100 }, createdAt: new Date() },
      { id: 2, type: 'CREATE_PEDIDO', status: 'pending', sucursalId: 1, userId: 'user-B', payload: { clienteId: 'de B', items: [], total: 200 }, createdAt: new Date() },
    ]

    beforeEach(() => {
      // Stand-in de IndexedDB con la misma regla de pertenencia que
      // getPendingOperations: lo del usuario activo y lo que no tiene dueño.
      mockGetPendingOperations.mockImplementation(async (...args: unknown[]) => {
        const userId = args[1] as string | null | undefined
        return colaDelTelefono.filter(op => !userId || op.userId == null || op.userId === userId)
      })
    })

    it('el usuario B no ve los pedidos de A', async () => {
      sesionActiva.userId = 'user-B'

      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))

      expect(result.current.pedidosPendientes[0].clienteId).toBe('de B')
      expect(mockGetPendingOperations).toHaveBeenCalledWith(100, 'user-B', 1)
    })

    it('el usuario B tampoco los replaya', async () => {
      sesionActiva.userId = 'user-B'

      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))
      await act(async () => { await result.current.sincronizarPedidos(mockCrearPedido) })

      expect(mockCrearPedido).toHaveBeenCalledTimes(1)
      expect(mockCrearPedido.mock.calls[0][0].clienteId).toBe('de B')
    })

    it('los pedidos de A siguen ahí cuando A vuelve a entrar', async () => {
      sesionActiva.userId = 'user-A'

      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))

      expect(result.current.pedidosPendientes[0].clienteId).toBe('de A')
    })
  })
})

/**
 * #961 — Las dos validaciones de stock offline (al encolar y antes del replay)
 * tienen que sumar por producto con el criterio del servidor: la venta suma, el
 * regalo suma sólo si su promo mueve stock. Antes cada línea se miraba sola.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'
import { useOfflineSync } from '../useOfflineSync'
import type { ProductoDB } from '../../types'

const mockQueueOperation = vi.fn().mockResolvedValue(1)
const mockGetPendingOperations = vi.fn().mockResolvedValue([])
const mockMarkAsFailed = vi.fn().mockResolvedValue(undefined)

vi.mock('../../lib/offlineDb', () => ({
  queueOperation: (...args: unknown[]) => mockQueueOperation(...args),
  getPendingOperations: (...args: unknown[]) => mockGetPendingOperations(...args),
  markAsCompleted: vi.fn().mockResolvedValue(undefined),
  markAsFailed: (...args: unknown[]) => mockMarkAsFailed(...args),
  cleanupOldOperations: vi.fn().mockResolvedValue(0),
  deletePendingOperation: vi.fn().mockResolvedValue(undefined),
  deletePendingOperations: vi.fn().mockResolvedValue(0),
}))

vi.mock('../../lib/supabase', () => ({
  supabase: {
    from: vi.fn(),
    rpc: vi.fn(),
    rest: { headers: {} },
    auth: { refreshSession: vi.fn().mockResolvedValue({ data: { session: { user: { id: 'user-A' } } }, error: null }) },
  },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({
    userId: 'user-A',
    currentSucursalId: 1,
    sucursales: [{ id: 1, nombre: 'Test', rol: 'admin' }],
    loading: false,
    switchSucursal: vi.fn(),
  }),
}))

const PRODUCTOS: ProductoDB[] = [
  { id: 'naranja', nombre: 'Manaos Naranja 3L', stock: 50, precio: 1000, activo: true } as ProductoDB,
  { id: 'manzana', nombre: 'Manaos Manzana 3L', stock: 50, precio: 1000, activo: true } as ProductoDB,
]

// Naranja: 45 comprados + 10 de regalo que mueve stock = 55 contra un stock de 50.
const compra = { productoId: 'naranja', cantidad: 45, precioUnitario: 1000 }
const regaloQueMueve = { productoId: 'naranja', cantidad: 10, precioUnitario: 0, esBonificacion: true, promocionId: 'p1', regaloMueveStock: true }
const regaloFraccion = { ...regaloQueMueve, regaloMueveStock: false }

function opPendiente(items: unknown[]) {
  return [{
    id: 9,
    type: 'CREATE_PEDIDO',
    status: 'pending',
    sucursalId: 1,
    userId: 'user-A',
    payload: { clienteId: '123', items, total: 45000, offlineUuid: 'uuid-stock' },
    createdAt: new Date(),
  }]
}

describe('useOfflineSync — stock sumado por producto (#961)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockQueueOperation.mockResolvedValue(1)
    mockGetPendingOperations.mockResolvedValue([])
    Object.defineProperty(navigator, 'onLine', { value: false, writable: true, configurable: true })
  })

  describe('al encolar', () => {
    it('rechaza un producto comprado y regalado que juntos superan el stock, sin encolar', async () => {
      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toEqual([]))

      let guardado: Awaited<ReturnType<typeof result.current.guardarPedidoOffline>>
      await act(async () => {
        guardado = await result.current.guardarPedidoOffline(
          { clienteId: '123', items: [compra, regaloQueMueve], total: 45000 },
          { productos: PRODUCTOS, validarStock: true },
        )
      })

      expect(guardado!.success).toBe(false)
      expect(guardado!.itemsSinStock).toEqual([
        { productoId: 'naranja', nombre: 'Manaos Naranja 3L', solicitado: 55, disponible: 50 },
      ])
      expect(mockQueueOperation).not.toHaveBeenCalled()
    })

    it('encola si el regalo no mueve stock (fracción): no compite por el stock del producto', async () => {
      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toEqual([]))

      let guardado: Awaited<ReturnType<typeof result.current.guardarPedidoOffline>>
      await act(async () => {
        guardado = await result.current.guardarPedidoOffline(
          { clienteId: '123', items: [compra, regaloFraccion], total: 45000 },
          { productos: PRODUCTOS, validarStock: true },
        )
      })

      expect(guardado!.success).toBe(true)
      expect(mockQueueOperation).toHaveBeenCalledTimes(1)
    })
  })

  describe('antes del replay', () => {
    it('marca como fallido, sin mandarlo, un pedido cuyo producto comprado y regalado supera el stock', async () => {
      mockGetPendingOperations.mockResolvedValue(opPendiente([compra, regaloQueMueve]))
      Object.defineProperty(navigator, 'onLine', { value: true, writable: true, configurable: true })
      const crearPedido = vi.fn().mockResolvedValue({ id: 1, success: true })

      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))
      let sync: Awaited<ReturnType<typeof result.current.sincronizarPedidos>>
      await act(async () => { sync = await result.current.sincronizarPedidos(crearPedido, PRODUCTOS) })

      expect(crearPedido).not.toHaveBeenCalled()
      expect(mockMarkAsFailed).toHaveBeenCalledWith(9, expect.stringContaining('Stock insuficiente'))
      expect(sync!.conflictos).toHaveLength(1)
      expect(sync!.conflictos![0].items).toEqual([
        expect.objectContaining({ productoId: 'naranja', solicitado: 55, stockActual: 50 }),
      ])
    })

    it('sincroniza el mismo pedido si el regalo no mueve stock', async () => {
      mockGetPendingOperations.mockResolvedValue(opPendiente([compra, regaloFraccion]))
      Object.defineProperty(navigator, 'onLine', { value: true, writable: true, configurable: true })
      const crearPedido = vi.fn().mockResolvedValue({ id: 1, success: true })

      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))
      await act(async () => { await result.current.sincronizarPedidos(crearPedido, PRODUCTOS) })

      expect(crearPedido).toHaveBeenCalledTimes(1)
      expect(mockMarkAsFailed).not.toHaveBeenCalled()
    })
  })
})

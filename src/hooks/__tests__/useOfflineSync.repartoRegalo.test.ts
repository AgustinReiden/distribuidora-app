/**
 * Un regalo repartido en sabores al crear el pedido son N líneas de
 * bonificación de la MISMA promo (ver `RegaloOverride` en
 * utils/orquestacionPrecios). Sin señal, el pedido se encola: la cola es un
 * array de ítems y tiene que guardar y replayar las N líneas tal cual, sin
 * colapsarlas ni convertirlas en ítems cobrados.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'
import { useOfflineSync } from '../useOfflineSync'
import type { ProductoDB } from '../../types'

const mockQueueOperation = vi.fn().mockResolvedValue(1)
const mockGetPendingOperations = vi.fn().mockResolvedValue([])

vi.mock('../../lib/offlineDb', () => ({
  queueOperation: (...args: unknown[]) => mockQueueOperation(...args),
  getPendingOperations: (...args: unknown[]) => mockGetPendingOperations(...args),
  markAsCompleted: vi.fn().mockResolvedValue(undefined),
  markAsFailed: vi.fn().mockResolvedValue(undefined),
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
  { id: 'naranja', nombre: 'Manaos Naranja 3L', stock: 100, precio: 1000, activo: true } as ProductoDB,
  { id: 'manzana', nombre: 'Manaos Manzana 3L', stock: 100, precio: 1000, activo: true } as ProductoDB,
]

// 48 de naranja comprados → 24 de regalo, repartidos 12 naranja + 12 manzana.
const ITEMS_CON_REPARTO = [
  { productoId: 'naranja', cantidad: 48, precioUnitario: 1000, neto_unitario: 826.45, iva_unitario: 173.55, porcentaje_iva: 21 },
  { productoId: 'naranja', cantidad: 12, precioUnitario: 0, esBonificacion: true, promocionId: 'promo-24' },
  { productoId: 'manzana', cantidad: 12, precioUnitario: 0, esBonificacion: true, promocionId: 'promo-24' },
]

describe('useOfflineSync — regalo repartido en sabores', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockQueueOperation.mockResolvedValue(1)
    mockGetPendingOperations.mockResolvedValue([])
    Object.defineProperty(navigator, 'onLine', { value: false, writable: true, configurable: true })
  })

  it('encola las dos líneas de bonificación de la misma promo, cada una con su cantidad', async () => {
    const { result } = renderHook(() => useOfflineSync())
    await waitFor(() => expect(result.current.pedidosPendientes).toEqual([]))

    let guardado: Awaited<ReturnType<typeof result.current.guardarPedidoOffline>>
    await act(async () => {
      guardado = await result.current.guardarPedidoOffline(
        { clienteId: '123', items: ITEMS_CON_REPARTO, total: 48000 },
        { productos: PRODUCTOS, validarStock: true },
      )
    })

    expect(guardado!.success).toBe(true)
    const llamadas = mockQueueOperation.mock.calls
    const payload = llamadas[llamadas.length - 1]?.[1] as { items: unknown[] }
    expect(payload.items).toHaveLength(3)
    const bonifs = (payload.items as Array<Record<string, unknown>>).filter(i => i.esBonificacion)
    expect(bonifs).toEqual([
      expect.objectContaining({ productoId: 'naranja', cantidad: 12, precioUnitario: 0, promocionId: 'promo-24' }),
      expect.objectContaining({ productoId: 'manzana', cantidad: 12, precioUnitario: 0, promocionId: 'promo-24' }),
    ])
  })

  it('el replay manda las dos líneas al alta, como bonificación', async () => {
    mockGetPendingOperations.mockResolvedValue([{
      id: 7,
      type: 'CREATE_PEDIDO',
      status: 'pending',
      sucursalId: 1,
      userId: 'user-A',
      payload: { clienteId: '123', items: ITEMS_CON_REPARTO, total: 48000, offlineUuid: 'uuid-reparto' },
      createdAt: new Date(),
    }])
    Object.defineProperty(navigator, 'onLine', { value: true, writable: true, configurable: true })
    const crearPedido = vi.fn().mockResolvedValue({ id: 1, success: true })

    const { result } = renderHook(() => useOfflineSync())
    await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))
    await act(async () => { await result.current.sincronizarPedidos(crearPedido) })

    expect(crearPedido).toHaveBeenCalledTimes(1)
    const items = crearPedido.mock.calls[0][0].items as Array<Record<string, unknown>>
    expect(items).toHaveLength(3)
    expect(items.filter(i => i.esBonificacion)).toEqual([
      expect.objectContaining({ productoId: 'naranja', cantidad: 12, promocionId: 'promo-24' }),
      expect.objectContaining({ productoId: 'manzana', cantidad: 12, promocionId: 'promo-24' }),
    ])
  })
})

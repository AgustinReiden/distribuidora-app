/**
 * #1543 variante 4 — un alta online perdida después del COMMIT, y el segundo
 * intento sale sin red. La cola acuñaba su propia clave (`offlineUuid`), así que
 * el replay le hablaba a `crear_pedido_idempotente` con una clave que el server
 * nunca vio y creaba un segundo pedido. Con la clave del alta online, el replay
 * recibe el pedido que ya había entrado.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'
import { useOfflineSync } from '../useOfflineSync'

const mockQueueOperation = vi.fn().mockResolvedValue(1)
const mockGetPendingOperations = vi.fn().mockResolvedValue([])

vi.mock('../../lib/offlineDb', () => ({
  queueOperation: (...args: unknown[]) => mockQueueOperation(...args),
  getPendingOperations: (...args: unknown[]) => mockGetPendingOperations(...args),
  markAsCompleted: vi.fn().mockResolvedValue(undefined),
  markAsFailed: vi.fn().mockResolvedValue(undefined),
  cleanupOldOperations: vi.fn().mockResolvedValue(0),
  cleanupOldSyncEvents: vi.fn().mockResolvedValue(0),
  anotarFalloDeRed: vi.fn().mockResolvedValue(undefined),
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

const PEDIDO = { clienteId: '123', items: [{ productoId: 'p', cantidad: 10, precioUnitario: 1000 }], total: 10000 }

async function encolar(opciones: { claveDeAlta?: string }) {
  const { result } = renderHook(() => useOfflineSync())
  await waitFor(() => expect(result.current.pedidosPendientes).toEqual([]))
  await act(async () => {
    await result.current.guardarPedidoOffline(PEDIDO, { validarStock: false, ...opciones })
  })
  return mockQueueOperation.mock.calls[0][1] as Record<string, unknown>
}

describe('useOfflineSync — la clave del alta online viaja a la cola (#1543)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockQueueOperation.mockResolvedValue(1)
    mockGetPendingOperations.mockResolvedValue([])
    Object.defineProperty(navigator, 'onLine', { value: false, writable: true, configurable: true })
  })

  it('se encola con la clave del alta y el replay la manda como offlineId', async () => {
    const payload = await encolar({ claveDeAlta: 'clave-online-1' })
    expect(payload.offlineUuid).toBe('clave-online-1')

    // El replay de esa misma entrada: el server ya tiene un pedido con la clave y
    // contesta idempotente con el mismo cliente y total.
    mockGetPendingOperations.mockResolvedValue([{
      id: 1, type: 'CREATE_PEDIDO', status: 'pending', sucursalId: 1, userId: 'user-A', payload, createdAt: new Date(),
    }])
    Object.defineProperty(navigator, 'onLine', { value: true, writable: true, configurable: true })
    const crearPedido = vi.fn().mockResolvedValue({ id: '501', idempotente: true, clienteId: '123', total: 10000, cargoEnvio: 0 })

    const { result } = renderHook(() => useOfflineSync())
    await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))
    let sync: Awaited<ReturnType<typeof result.current.sincronizarPedidos>>
    await act(async () => { sync = await result.current.sincronizarPedidos(crearPedido) })

    expect(crearPedido).toHaveBeenCalledTimes(1)
    expect(crearPedido.mock.calls[0][0].offlineId).toBe('clave-online-1')
    expect(sync!.sincronizados).toBe(1)
  })

  it('sin clave del alta, la cola acuña la suya', async () => {
    const payload = await encolar({})
    expect(typeof payload.offlineUuid).toBe('string')
    expect(payload.offlineUuid).not.toBe('')
  })
})

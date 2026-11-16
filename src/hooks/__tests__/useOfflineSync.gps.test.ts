/**
 * #1602 — el pedido cargado sin señal registra su GPS al sincronizar. Antes el
 * alta encolada cortaba antes de registrar el GPS y el replay no lo conocía:
 * cerca de un cuarto de los pedidos de preventistas de una sucursal quedaba con
 * `gps_status` nulo.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'
import { useOfflineSync } from '../useOfflineSync'

const mockQueueOperation = vi.fn().mockResolvedValue(1)
const mockGetPendingOperations = vi.fn().mockResolvedValue([])
const mockRegistrarGps = vi.fn().mockResolvedValue(undefined)

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

vi.mock('../useRegistrarGeolocalizacionPedido', () => ({
  registrarGeolocalizacionPedido: (...args: unknown[]) => mockRegistrarGps(...args),
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
    currentSucursalId: 4,
    sucursales: [{ id: 4, nombre: 'Test', rol: 'preventista' }],
    loading: false,
    switchSucursal: vi.fn(),
  }),
}))

const PEDIDO = { clienteId: '123', items: [{ productoId: 'p', cantidad: 10, precioUnitario: 1000 }], total: 10000 }
const GPS = {
  status: 'denied' as const,
  diagnostico: { permiso: 'denied' as const, error: 1, instalada: true, navegador: 'chrome 131', so: 'android 10' },
}

async function encolarYSincronizar(extra: Record<string, unknown>, respuesta: unknown) {
  Object.defineProperty(navigator, 'onLine', { value: false, writable: true, configurable: true })
  const enc = renderHook(() => useOfflineSync())
  await waitFor(() => expect(enc.result.current.pedidosPendientes).toEqual([]))
  await act(async () => {
    await enc.result.current.guardarPedidoOffline({ ...PEDIDO, ...extra }, { validarStock: false })
  })
  const payload = mockQueueOperation.mock.calls[0][1] as Record<string, unknown>

  mockGetPendingOperations.mockResolvedValue([{
    id: 1, type: 'CREATE_PEDIDO', status: 'pending', sucursalId: 4, userId: 'user-A', payload, createdAt: new Date(),
  }])
  Object.defineProperty(navigator, 'onLine', { value: true, writable: true, configurable: true })
  const crearPedido = vi.fn().mockResolvedValue(respuesta)
  const { result } = renderHook(() => useOfflineSync())
  await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))
  let sync: Awaited<ReturnType<typeof result.current.sincronizarPedidos>>
  await act(async () => { sync = await result.current.sincronizarPedidos(crearPedido) })
  return { payload, sync: sync! }
}

describe('useOfflineSync — el GPS del pedido encolado (#1602)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockQueueOperation.mockResolvedValue(1)
    mockGetPendingOperations.mockResolvedValue([])
  })

  it('el GPS y su motivo se encolan, y el replay los registra con la sucursal de la operación', async () => {
    const { payload, sync } = await encolarYSincronizar(
      { gps: GPS, gpsMotivoOmision: 'sin permiso en el teléfono' },
      { id: '777' },
    )
    expect(payload.gps).toEqual(GPS)
    expect(sync.sincronizados).toBe(1)
    await waitFor(() => expect(mockRegistrarGps).toHaveBeenCalledTimes(1))
    expect(mockRegistrarGps).toHaveBeenCalledWith('777', GPS, 'sin permiso en el teléfono', { sucursalId: 4 })
  })

  it('un pedido encolado sin GPS (admin, o de un bundle viejo) no registra nada', async () => {
    const { sync } = await encolarYSincronizar({}, { id: '778' })
    expect(sync.sincronizados).toBe(1)
    expect(mockRegistrarGps).not.toHaveBeenCalled()
  })

  it('si la respuesta idempotente es de OTRO pedido, no se le escribe el GPS', async () => {
    const { sync } = await encolarYSincronizar(
      { gps: GPS },
      { id: '900', idempotente: true, clienteId: '999', total: 1, cargoEnvio: 0 },
    )
    expect(sync.sincronizados).toBe(0)
    expect(mockRegistrarGps).not.toHaveBeenCalled()
  })
})

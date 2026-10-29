/**
 * #1264 — El replay tiene que llegar a `crear_pedido_idempotente`.
 *
 * La RPC es idempotente por `offline_id` (advisory lock y rama idempotente en
 * el servidor), pero el front no siempre la llamaba: revalidaba el stock local
 * ANTES, y un pedido que el servidor ya había registrado —con la respuesta
 * perdida, o con la pestaña muerta antes de `markAsCompleted`— encontraba su
 * propio stock ya descontado ("necesita 1, disponible 0") y quedaba fallido
 * sin preguntarle al servidor. Si alguien lo recargaba a mano, se duplicaba.
 *
 * Estos tests corren contra la cola real (Dexie sobre fake-indexeddb) y un
 * servidor falso con la misma regla de idempotencia que la RPC.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'
import { useOfflineSync, type CrearPedidoFunction } from '../useOfflineSync'
import { db, clearAllData, queueOperation, getPendingOperations, getFailedOperations } from '../../lib/offlineDb'
import { RechazoDeNegocioError } from '../../utils/rechazoDeNegocio'
import type { ProductoDB } from '../../types'

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
    sucursales: [{ id: 1, nombre: 'Test', rol: 'preventista' }],
    loading: false,
    switchSucursal: vi.fn(),
  }),
}))

type Input = Parameters<CrearPedidoFunction>[0]

/**
 * Lo que hace `crear_pedido_idempotente` visto desde afuera: una clave ya
 * registrada devuelve el pedido existente con `idempotente: true` (antes de
 * mirar el stock); una nueva valida stock, lo descuenta y registra.
 */
function servidorFalso(stockInicial: Record<string, number>) {
  const pedidos = new Map<string, { clienteId: string | number; total: number }>()
  const stock = { ...stockInicial }

  async function crear(input: Input): Promise<unknown> {
    const clave = String(input.offlineId)
    const previo = pedidos.get(clave)
    if (previo) return { idempotente: true, clienteId: previo.clienteId, total: previo.total, cargoEnvio: 0 }

    for (const item of input.items) {
      const disponible = stock[item.productoId] ?? 0
      if (disponible < item.cantidad) {
        throw new RechazoDeNegocioError(
          `${item.productoId}: stock insuficiente (disponible: ${disponible}, solicitado: ${item.cantidad})`
        )
      }
    }
    for (const item of input.items) stock[item.productoId] -= item.cantidad
    pedidos.set(clave, { clienteId: input.clienteId, total: input.total })
    return { id: pedidos.size }
  }

  return { pedidos, stock, crear }
}

const ITEMS = [{ productoId: 'p1', cantidad: 1, precioUnitario: 100 }]
const PAYLOAD = { clienteId: '7', items: ITEMS, total: 100, offlineUuid: 'uuid-1264' }

function productos(stock: number): ProductoDB[] {
  return [{ id: 'p1', nombre: 'Producto 1', stock, precio: 100, activo: true } as ProductoDB]
}

describe('useOfflineSync — replay idempotente (#1264)', () => {
  beforeEach(async () => {
    vi.clearAllMocks()
    await clearAllData()
    Object.defineProperty(navigator, 'onLine', { value: true, writable: true, configurable: true })
  })

  describe('respuesta perdida', () => {
    it('el pedido que el servidor ya registró se da por sincronizado aunque el stock local ya esté descontado', async () => {
      const servidor = servidorFalso({ p1: 1 })
      const id = await queueOperation('CREATE_PEDIDO', PAYLOAD, 'user-A', 5, 1)

      // Primer intento: el servidor lo registra y descuenta el stock, pero la
      // respuesta no llega (o iOS mata la pestaña antes de markAsCompleted).
      await servidor.crear({ ...PAYLOAD, offlineId: 'uuid-1264' })
      expect(servidor.stock.p1).toBe(0)

      // Al volver, la app ya refrescó los productos: su stock refleja ESTE pedido.
      const crear = vi.fn(servidor.crear)
      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))

      let sync: Awaited<ReturnType<typeof result.current.sincronizarPedidos>>
      await act(async () => { sync = await result.current.sincronizarPedidos(crear, productos(0)) })

      // Le preguntó al servidor con la misma clave, y el servidor dijo "ya lo tengo".
      expect(crear).toHaveBeenCalledWith(expect.objectContaining({ offlineId: 'uuid-1264' }))
      expect(sync!.sincronizados).toBe(1)
      expect(sync!.conflictos).toBeUndefined()
      expect((await db.pendingOperations.get(id))!.status).toBe('completed')
      // Nada fallido que alguien pueda "recargar a mano" y duplicar.
      expect(await getFailedOperations(10, 'user-A', 1)).toHaveLength(0)
      expect(await getPendingOperations(10, 'user-A', 1)).toHaveLength(0)
      expect(servidor.pedidos.size).toBe(1)
    })

    it('un pedido nuevo sin stock en el servidor sigue quedando en la cola, con el conflicto descripto', async () => {
      // El servidor decide el stock; el teléfono sólo lo describe.
      const servidor = servidorFalso({ p1: 0 })
      const id = await queueOperation('CREATE_PEDIDO', PAYLOAD, 'user-A', 5, 1)

      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))

      let sync: Awaited<ReturnType<typeof result.current.sincronizarPedidos>>
      await act(async () => { sync = await result.current.sincronizarPedidos(servidor.crear, productos(0)) })

      expect(sync!.sincronizados).toBe(0)
      expect(sync!.conflictos).toHaveLength(1)
      expect(sync!.conflictos![0].items).toEqual([
        expect.objectContaining({ productoId: 'p1', solicitado: 1, stockActual: 0 }),
      ])
      const op = (await db.pendingOperations.get(id))!
      // No terminal: puede entrar mercadería.
      expect(op.status).toBe('pending')
      expect(op.retryCount).toBe(1)
      expect(op.lastError).toMatch(/stock insuficiente/i)
      expect(servidor.pedidos.size).toBe(0)
    })
  })

  describe('mala señal', () => {
    it('un fallo sin respuesta del servidor no lo vuelve fallido: sigue pendiente, con el motivo', async () => {
      // maxRetries 1: con la política vieja, un solo sync sin red lo dejaba
      // `failed`, fuera de la cola y del contador.
      const id = await queueOperation('CREATE_PEDIDO', PAYLOAD, 'user-A', 1, 1)
      const crear = vi.fn().mockRejectedValue({ message: 'TypeError: Failed to fetch', code: '' })

      const { result } = renderHook(() => useOfflineSync())
      await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(1))
      await act(async () => { await result.current.sincronizarPedidos(crear) })

      const op = (await db.pendingOperations.get(id))!
      expect(op.status).toBe('pending')
      expect(op.retryCount).toBe(0)
      expect(op.lastError).toBe('TypeError: Failed to fetch')
      expect(result.current.pedidosPendientes).toHaveLength(1)
      expect(result.current.pedidosPendientes[0].ultimoError).toBe('TypeError: Failed to fetch')
      expect(await getFailedOperations(10, 'user-A', 1)).toHaveLength(0)
    })
  })

  describe('dos pestañas', () => {
    it('si la otra pestaña ya lo completó, el fallo de ésta no lo devuelve a la cola', async () => {
      const servidor = servidorFalso({ p1: 10 })
      const id = await queueOperation('CREATE_PEDIDO', PAYLOAD, 'user-A', 5, 1)

      // Pestaña A: su llamada queda en vuelo hasta que la soltemos.
      let soltarA!: () => void
      const crearA = vi.fn((input: Input) => new Promise<unknown>(resolve => {
        soltarA = () => resolve(servidor.crear(input))
      }))
      // Pestaña B: leyó la misma operación pendiente, y su llamada termina mal
      // (un error del servidor que no es de red, así que no hay backoff).
      let fallarB!: () => void
      const crearB = vi.fn(() => new Promise<unknown>((_, reject) => {
        fallarB = () => reject({ message: 'canceling statement due to statement timeout', code: '57014' })
      }))

      const pestanaA = renderHook(() => useOfflineSync())
      const pestanaB = renderHook(() => useOfflineSync())
      await waitFor(() => expect(pestanaA.result.current.pedidosPendientes).toHaveLength(1))
      await waitFor(() => expect(pestanaB.result.current.pedidosPendientes).toHaveLength(1))

      let syncA!: Promise<unknown>
      let syncB!: Promise<unknown>
      act(() => { syncA = pestanaA.result.current.sincronizarPedidos(crearA) })
      await waitFor(() => expect(crearA).toHaveBeenCalledTimes(1))
      act(() => { syncB = pestanaB.result.current.sincronizarPedidos(crearB) })
      await waitFor(() => expect(crearB).toHaveBeenCalledTimes(1))

      // A termina primero y la completa...
      await act(async () => { soltarA(); await syncA })
      expect((await db.pendingOperations.get(id))!.status).toBe('completed')

      // ...y después falla B.
      await act(async () => { fallarB(); await syncB })

      const op = (await db.pendingOperations.get(id))!
      expect(op.status).toBe('completed')
      expect(op.retryCount).toBe(0)
      expect(await getPendingOperations(10, 'user-A', 1)).toHaveLength(0)
      expect(await getFailedOperations(10, 'user-A', 1)).toHaveLength(0)
      expect(servidor.pedidos.size).toBe(1)
    })
  })
})

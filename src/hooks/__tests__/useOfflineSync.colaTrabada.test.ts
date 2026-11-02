/**
 * #1303 y #1304 — La cola no se traba ni clasifica mal lo que le contesta el
 * servidor.
 *
 * Corren contra la cola real (Dexie sobre fake-indexeddb) y un servidor falso con
 * la misma regla de idempotencia que `crear_pedido_idempotente`: lo que importa
 * acá es en qué estado queda la operación después de cada respuesta.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'
import { createClient } from '@supabase/supabase-js'
import {
  useOfflineSync,
  PLAZO_INTENTO_REPLAY_MS,
  type CrearPedidoFunction,
  type SyncResult,
} from '../useOfflineSync'
import { db, clearAllData, queueOperation, getFailedOperations } from '../../lib/offlineDb'
import { RechazoDeNegocioError } from '../../utils/rechazoDeNegocio'
import { errorDeSupabase, respuestaDeErrorLegible } from '../../utils/errorDeSupabase'
import { supabase } from '../../lib/supabase'

vi.mock('../../lib/supabase', () => ({
  supabase: {
    from: vi.fn(),
    rpc: vi.fn(),
    rest: { headers: {} },
    auth: { refreshSession: vi.fn() },
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
type Hook = { current: ReturnType<typeof useOfflineSync> }

const renovar = vi.mocked(supabase.auth.refreshSession)
const SESION_OK = { data: { session: { user: { id: 'user-A' } } }, error: null }

/** `crear_pedido_idempotente` visto desde afuera. */
function servidorFalso() {
  const pedidos = new Map<string, { clienteId: string | number; total: number }>()

  async function crear(input: Input): Promise<unknown> {
    const clave = String(input.offlineId)
    const previo = pedidos.get(clave)
    if (previo) return { idempotente: true, clienteId: previo.clienteId, total: previo.total, cargoEnvio: 0 }
    pedidos.set(clave, { clienteId: input.clienteId, total: input.total })
    return { id: pedidos.size }
  }

  /** La escritura entra y la respuesta no vuelve nunca: señal que no pasa datos. */
  function crearYColgar(input: Input): Promise<unknown> {
    void crear(input)
    return new Promise(() => {})
  }

  return { pedidos, crear, crearYColgar }
}

const ITEMS = [{ productoId: 'p1', cantidad: 1, precioUnitario: 100 }]
const payload = (uuid: string) => ({ clienteId: '7', items: ITEMS, total: 100, offlineUuid: uuid })

async function hookConPendientes(cantidad: number): Promise<Hook> {
  const { result } = renderHook(() => useOfflineSync())
  await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(cantidad))
  return result
}

/**
 * Corre un sync hasta que el intento quede colgado y deja vencer el plazo.
 * Sólo se falsea `setTimeout`: Dexie avanza con `setImmediate`. Y `vi.waitFor`,
 * porque el `waitFor` de RTL espera un `setTimeout` que acá no pasa nunca.
 */
async function sincronizarHastaVencer(
  hook: Hook,
  crear: CrearPedidoFunction & { mock: unknown },
  llamadas = 1,
): Promise<SyncResult> {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] })
  let sync!: Promise<SyncResult>
  act(() => { sync = hook.current.sincronizarPedidos(crear) })
  await vi.waitFor(() => expect(crear).toHaveBeenCalledTimes(llamadas))
  await act(async () => { await vi.advanceTimersByTimeAsync(PLAZO_INTENTO_REPLAY_MS) })
  const resultado = await act(async () => sync)
  vi.useRealTimers()
  return resultado
}

beforeEach(async () => {
  await clearAllData()
  vi.clearAllMocks()
  renovar.mockResolvedValue(SESION_OK as never)
})

afterEach(() => {
  vi.useRealTimers()
})

describe('PLT-N3: el replay tiene plazo', () => {
  it('una escritura colgada queda pendiente sin gastar reintentos, y el reintento cae en la idempotencia', async () => {
    const servidor = servidorFalso()
    // maxRetries 1: si el corte gastara un reintento, quedaría fallida.
    const id = await queueOperation('CREATE_PEDIDO', payload('uuid-1'), 'user-A', 1, 1)
    const hook = await hookConPendientes(1)

    const colgada = vi.fn(servidor.crearYColgar)
    const primera = await sincronizarHastaVencer(hook, colgada)

    const op = (await db.pendingOperations.get(id))!
    expect(op.status).toBe('pending')
    expect(op.retryCount).toBe(0)
    expect(op.lastError).toMatch(/sin respuesta/i)
    expect(primera.sinRespuesta).toBe(1)
    expect(primera.errores).toEqual([])
    expect(hook.current.sincronizando).toBe(false)
    expect(servidor.pedidos.size).toBe(1)

    // Vuelve la señal: el sync no quedó bloqueado y el servidor ya lo tenía.
    let segunda!: SyncResult
    await act(async () => { segunda = await hook.current.sincronizarPedidos(servidor.crear) })

    expect(segunda.sincronizados).toBe(1)
    expect((await db.pendingOperations.get(id))!.status).toBe('completed')
    expect(servidor.pedidos.size).toBe(1)
  })

  it('al vencer aborta el request que estaba en vuelo', async () => {
    await queueOperation('CREATE_PEDIDO', payload('uuid-1'), 'user-A', 1, 1)
    const hook = await hookConPendientes(1)

    const senales: Array<AbortSignal | undefined> = []
    const colgada = vi.fn((input: Input) => {
      senales.push(input.signal)
      return new Promise<unknown>(() => {})
    })
    await sincronizarHastaVencer(hook, colgada)

    expect(senales).toHaveLength(1)
    expect(senales[0]?.aborted).toBe(true)
  })

  it('un intento colgado no se repite en la misma ronda', async () => {
    await queueOperation('CREATE_PEDIDO', payload('uuid-1'), 'user-A', 5, 1)
    const hook = await hookConPendientes(1)

    const colgada = vi.fn(() => new Promise<unknown>(() => {}))
    await sincronizarHastaVencer(hook, colgada)

    expect(colgada).toHaveBeenCalledTimes(1)
  })

  it('corta la ronda: el resto de la cola no paga un plazo por pedido', async () => {
    const primera = await queueOperation('CREATE_PEDIDO', payload('uuid-1'), 'user-A', 5, 1)
    const segunda = await queueOperation('CREATE_PEDIDO', payload('uuid-2'), 'user-A', 5, 1)
    const hook = await hookConPendientes(2)

    const colgada = vi.fn(() => new Promise<unknown>(() => {}))
    const resultado = await sincronizarHastaVencer(hook, colgada)

    expect(colgada).toHaveBeenCalledTimes(1)
    expect(resultado.sinRespuesta).toBe(2)
    expect(resultado.success).toBe(false)
    expect((await db.pendingOperations.get(primera))!.lastError).toMatch(/sin respuesta/i)
    expect((await db.pendingOperations.get(segunda))!.status).toBe('pending')
    expect((await db.pendingOperations.get(segunda))!.lastError).toBeUndefined()
  })

  it('un corte a mitad de la cola respeta lo que ya entró y cuenta lo que falta', async () => {
    const servidor = servidorFalso()
    const primera = await queueOperation('CREATE_PEDIDO', payload('uuid-1'), 'user-A', 5, 1)
    await queueOperation('CREATE_PEDIDO', payload('uuid-2'), 'user-A', 5, 1)
    await queueOperation('CREATE_PEDIDO', payload('uuid-3'), 'user-A', 5, 1)
    const hook = await hookConPendientes(3)

    const crear = vi.fn(servidor.crearYColgar).mockImplementationOnce(servidor.crear)
    const resultado = await sincronizarHastaVencer(hook, crear, 2)

    expect(crear).toHaveBeenCalledTimes(2)
    expect(resultado.sincronizados).toBe(1)
    expect(resultado.sinRespuesta).toBe(2)
    expect((await db.pendingOperations.get(primera))!.status).toBe('completed')
  })

  it('una renovación de sesión colgada también respeta el plazo', async () => {
    const id = await queueOperation('CREATE_PEDIDO', payload('uuid-1'), 'user-A', 1, 1)
    const hook = await hookConPendientes(1)

    renovar.mockReturnValue(new Promise(() => {}) as never)
    const crear = vi.fn().mockRejectedValue({ message: 'JWT expired', details: null, hint: null, code: 'PGRST301' })
    const resultado = await sincronizarHastaVencer(hook, crear)

    expect(resultado.sinRespuesta).toBe(1)
    const op = (await db.pendingOperations.get(id))!
    expect(op.status).toBe('pending')
    expect(op.retryCount).toBe(0)
  })
})

describe('PLT-N4: la respuesta de idempotencia con la sesión vencida', () => {
  const OTRA_SUCURSAL = 'Ese pedido offline ya se sincronizo en otra sucursal. Cambia de sucursal para verlo.'

  it('renueva la sesión y vuelve a preguntar antes de creerle: el pedido era propio', async () => {
    const servidor = servidorFalso()
    const id = await queueOperation('CREATE_PEDIDO', payload('uuid-1'), 'user-A', 5, 1)
    const hook = await hookConPendientes(1)

    // Con el JWT vencido `current_sucursal_id()` da NULL, así que el pedido
    // propio parece de otra sucursal. Con la sesión nueva, la RPC lo reconoce.
    await servidor.crear({ clienteId: '7', items: ITEMS, total: 100, offlineId: 'uuid-1' })
    const crear = vi.fn(servidor.crear).mockRejectedValueOnce(new RechazoDeNegocioError(OTRA_SUCURSAL))

    let resultado!: SyncResult
    await act(async () => { resultado = await hook.current.sincronizarPedidos(crear) })

    expect(renovar).toHaveBeenCalledTimes(1)
    expect(crear).toHaveBeenCalledTimes(2)
    // El reintento tras renovar sigue dentro del plazo del intento.
    expect(crear.mock.calls[1][0].signal).toBe(crear.mock.calls[0][0].signal)
    expect(resultado.sincronizados).toBe(1)
    expect((await db.pendingOperations.get(id))!.status).toBe('completed')
    expect(servidor.pedidos.size).toBe(1)
  })

  it('si con la sesión renovada dice lo mismo, es verdad: queda fallida sin gastar la cola', async () => {
    const id = await queueOperation('CREATE_PEDIDO', payload('uuid-1'), 'user-A', 5, 1)
    const hook = await hookConPendientes(1)

    const crear = vi.fn().mockRejectedValue(new RechazoDeNegocioError(OTRA_SUCURSAL))
    await act(async () => { await hook.current.sincronizarPedidos(crear) })

    expect(renovar).toHaveBeenCalledTimes(1)
    expect(crear).toHaveBeenCalledTimes(2)
    const op = (await db.pendingOperations.get(id))!
    expect(op.status).toBe('failed')
    expect(op.retryCount).toBe(op.maxRetries)
    expect(await getFailedOperations(10, 'user-A', 1)).toHaveLength(1)
  })

  it('si no se pudo renovar no es terminal: todavía no se sabe de quién es', async () => {
    const id = await queueOperation('CREATE_PEDIDO', payload('uuid-1'), 'user-A', 5, 1)
    const hook = await hookConPendientes(1)

    renovar.mockResolvedValue({ data: { session: null }, error: { message: 'sin sesión' } } as never)
    const crear = vi.fn().mockRejectedValue(new RechazoDeNegocioError(OTRA_SUCURSAL))
    await act(async () => { await hook.current.sincronizarPedidos(crear) })

    const op = (await db.pendingOperations.get(id))!
    expect(op.status).toBe('pending')
    expect(op.retryCount).toBe(1)
  })

  it('un error de JWT se renueva por su code, aunque el texto no lo diga', async () => {
    const servidor = servidorFalso()
    const id = await queueOperation('CREATE_PEDIDO', payload('uuid-1'), 'user-A', 5, 1)
    const hook = await hookConPendientes(1)

    const crear = vi.fn(servidor.crear)
      .mockRejectedValueOnce({ message: 'JWSError JWSInvalidSignature', details: null, hint: null, code: 'PGRST301' })
    await act(async () => { await hook.current.sincronizarPedidos(crear) })

    expect(renovar).toHaveBeenCalledTimes(1)
    expect((await db.pendingOperations.get(id))!.status).toBe('completed')
  })
})

describe('PLT-N5: un 5xx del gateway', () => {
  const html524 = '<!DOCTYPE html><html><head><title>A timeout occurred | 524</title></head><body>Error code 524</body></html>'

  /** Lo que tira `crearPedido` ante esa respuesta: pasa por el cliente real. */
  async function errorDelGateway(respuesta: Response) {
    const cliente = createClient('https://proyecto.supabase.co', 'anon-key', {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { fetch: (async () => respuestaDeErrorLegible(respuesta)) as typeof fetch },
    })
    const { error } = await cliente.rpc('crear_pedido_idempotente', {})
    return errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el alta del pedido.')
  }

  it('gasta un reintento, sin importar que el HTML diga "timeout": no queda pendiente para siempre', async () => {
    const id = await queueOperation('CREATE_PEDIDO', payload('uuid-1'), 'user-A', 5, 1)
    const hook = await hookConPendientes(1)

    const crear = vi.fn().mockRejectedValue(await errorDelGateway(new Response(html524, { status: 524 })))
    let resultado!: SyncResult
    await act(async () => { resultado = await hook.current.sincronizarPedidos(crear) })

    // Sin backoff: no es un blip de señal.
    expect(crear).toHaveBeenCalledTimes(1)
    expect(resultado.sinRespuesta).toBe(0)
    expect(resultado.errores).toHaveLength(1)
    const op = (await db.pendingOperations.get(id))!
    expect(op.status).toBe('pending')
    expect(op.retryCount).toBe(1)
  })

  it('lastError guarda el status y no el HTML', async () => {
    const id = await queueOperation('CREATE_PEDIDO', payload('uuid-1'), 'user-A', 5, 1)
    const hook = await hookConPendientes(1)

    const crear = vi.fn().mockRejectedValue(await errorDelGateway(new Response(html524, { status: 524 })))
    await act(async () => { await hook.current.sincronizarPedidos(crear) })

    const { lastError } = (await db.pendingOperations.get(id))!
    expect(lastError).toContain('HTTP 524')
    expect(lastError).not.toContain('<')
  })

  it('un 502 sin palabra "timeout" se trata igual', async () => {
    const id = await queueOperation('CREATE_PEDIDO', payload('uuid-1'), 'user-A', 5, 1)
    const hook = await hookConPendientes(1)

    const crear = vi.fn().mockRejectedValue(await errorDelGateway(new Response('<html>Bad Gateway</html>', { status: 502 })))
    await act(async () => { await hook.current.sincronizarPedidos(crear) })

    const op = (await db.pendingOperations.get(id))!
    expect(op.retryCount).toBe(1)
    expect(op.lastError).toContain('HTTP 502')
  })
})

/**
 * Desde la 424 `pagos` no tiene INSERT REST, y `SYNC_PAGO` no tiene productor
 * desde #509. Un teléfono viejo podría tener una operación así en IndexedDB: el
 * replay no la manda, así que no recibe un 42501, y tampoco frena a los pedidos.
 */
describe('una operación de cobro vieja en la cola', () => {
  it('no se replaya y no traba a los pedidos', async () => {
    const servidor = servidorFalso()
    const cobro = await queueOperation('SYNC_PAGO', { pedido_id: 1, monto: 100 }, 'user-A', 5, 1)
    const pedido = await queueOperation('CREATE_PEDIDO', payload('uuid-1'), 'user-A', 5, 1)
    const hook = await hookConPendientes(1)

    const crear = vi.fn(servidor.crear)
    let resultado!: SyncResult
    await act(async () => { resultado = await hook.current.sincronizarPedidos(crear) })

    expect(crear).toHaveBeenCalledTimes(1)
    expect(resultado.sincronizados).toBe(1)
    expect((await db.pendingOperations.get(pedido))!.status).toBe('completed')
    expect((await db.pendingOperations.get(cobro))!.retryCount).toBe(0)
  })
})

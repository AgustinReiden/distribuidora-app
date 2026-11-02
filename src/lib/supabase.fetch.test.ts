/**
 * El `fetch` que `supabase.ts` le pasa al cliente, con el cliente real.
 *
 * Los tests del resto del repo mockean este módulo, así que esto es lo único que
 * prueba cómo llega una respuesta a la app. `vi.stubEnv` porque sin `.env` el
 * cliente no se puede crear, y los tests corren sin `.env` (trampa 1).
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

const html524 = '<!DOCTYPE html><html><head><title>A timeout occurred | 524</title></head><body>Error code 524</body></html>'

type Init = NonNullable<Parameters<typeof fetch>[1]>

const fetchFalso = vi.fn<(url: string, init: Init) => Promise<Response>>()

function pedidoA(fragmento: string) {
  return fetchFalso.mock.calls.find(([url]) => String(url).includes(fragmento))
}

/** Un fetch de verdad: queda pendiente y sólo lo corta la señal. */
function fetchColgado(_url: string, init: Init): Promise<Response> {
  return new Promise((_, reject) => {
    init.signal?.addEventListener('abort', () => reject(init.signal?.reason))
  })
}

async function cargarCliente() {
  return import('./supabase')
}

beforeEach(() => {
  vi.resetModules()
  fetchFalso.mockReset()
  vi.stubEnv('VITE_SUPABASE_URL', 'https://proyecto.supabase.co')
  vi.stubEnv('VITE_SUPABASE_ANON_KEY', 'anon-key')
  vi.stubGlobal('fetch', fetchFalso)
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllEnvs()
  vi.unstubAllGlobals()
})

describe('fetch de supabase.ts', () => {
  it('manda la sucursal activa', async () => {
    fetchFalso.mockResolvedValue(new Response('{}'))
    const { supabase, setSucursalHeader } = await cargarCliente()

    setSucursalHeader(3)
    await supabase.rpc('alguna_rpc', {})

    const [, init] = pedidoA('alguna_rpc')!
    expect(new Headers(init.headers).get('X-Sucursal-ID')).toBe('3')
  })

  describe('un error de gateway en PostgREST (#1304)', () => {
    it('llega con su status como code, no con el HTML', async () => {
      fetchFalso.mockResolvedValue(new Response(html524, { status: 524 }))
      const { supabase } = await cargarCliente()

      const { error } = await supabase.rpc('crear_pedido_idempotente', {})

      expect(error?.code).toBe('HTTP_524')
      expect(error?.message).not.toContain('<')
    })
  })

  describe('las otras APIs no se tocan', () => {
    it('el error de una edge function conserva su cuerpo: ModalCompra lo lee', async () => {
      fetchFalso.mockResolvedValue(new Response('{"error":"factura ilegible"}', { status: 500 }))
      const { supabase } = await cargarCliente()

      const { error } = await supabase.functions.invoke('escanear-factura', { body: {} })

      expect(error?.name).toBe('FunctionsHttpError')
      expect(await error.context.text()).toBe('{"error":"factura ilegible"}')
    })
  })

  /**
   * Los dos caminos del plazo (#1303): el replay corta porque pasa su señal, y
   * nada más corta. Un plazo acá adentro cortaría una subida o una descarga larga
   * que están andando, aunque lentas.
   */
  describe('el plazo es del que lo pide, no del fetch', () => {
    const DIEZ_MINUTOS = 10 * 60 * 1000

    beforeEach(() => {
      vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] })
    })

    it('una subida larga no se corta', async () => {
      fetchFalso.mockImplementation(fetchColgado)
      const { supabase } = await cargarCliente()

      const subida = supabase.storage.from('facturas').upload('a.pdf', new Blob(['x']))
      subida.catch(() => {})
      await vi.waitFor(() => expect(pedidoA('/storage/v1/')).toBeTruthy())
      await vi.advanceTimersByTimeAsync(DIEZ_MINUTOS)

      const [, init] = pedidoA('/storage/v1/')!
      expect(init.signal?.aborted ?? false).toBe(false)
    })

    it('una descarga larga por REST no se corta', async () => {
      fetchFalso.mockImplementation(fetchColgado)
      const { supabase } = await cargarCliente()

      const descarga = supabase.from('pedidos').select('id').then(r => r)
      void descarga
      await vi.waitFor(() => expect(pedidoA('/rest/v1/pedidos')).toBeTruthy())
      await vi.advanceTimersByTimeAsync(DIEZ_MINUTOS)

      const [, init] = pedidoA('/rest/v1/pedidos')!
      expect(init.signal?.aborted ?? false).toBe(false)
    })

    it('la señal del que la pide sí corta, y queda como fallo de red', async () => {
      const { isTransientNetworkError, PlazoDeRedVencido } = await import('../utils/retryWithBackoff')
      fetchFalso.mockImplementation(fetchColgado)
      const { supabase } = await cargarCliente()

      const controlador = new AbortController()
      const pedido = supabase.rpc('crear_pedido_idempotente', {}).abortSignal(controlador.signal).then(r => r)
      await vi.waitFor(() => expect(pedidoA('crear_pedido_idempotente')).toBeTruthy())
      controlador.abort(new PlazoDeRedVencido(20_000))

      const { error } = await pedido
      expect(error?.code).toBe('')
      expect(isTransientNetworkError(error)).toBe(true)
    })
  })
})

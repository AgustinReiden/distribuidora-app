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

  // 1601-b5 (#1601): el build va en el X-Client-Info, para medir en los logs del gateway si
  // quedan bundles viejos antes de cerrar una columna. Una sola vez, en REST y en Storage.
  it('suma el build al X-Client-Info de supabase-js, una sola vez', async () => {
    fetchFalso.mockResolvedValue(new Response('{}'))
    const { supabase, MARCA_DE_BUILD } = await cargarCliente()

    await supabase.from('perfiles').select('id')
    await supabase.storage.from('facturas').createSignedUrl('1/x.pdf', 60)

    const [, rest] = pedidoA('/rest/v1/perfiles')!
    const [, storage] = pedidoA('/storage/v1/')!
    for (const init of [rest, storage]) {
      const info = new Headers(init.headers).get('X-Client-Info') ?? ''
      expect(info).toMatch(/^supabase-js-/)
      expect(info.endsWith(` ${MARCA_DE_BUILD}`)).toBe(true)
      expect(info.split(MARCA_DE_BUILD)).toHaveLength(2)
    }
    expect(MARCA_DE_BUILD).toMatch(/^distribuidora\/\S+$/)
  })

  // INF-2 (#1563): el replay de la cola manda la sucursal de cada operación en el
  // request; el wrapper no se la pisa con la de la pantalla, ni la de la pantalla cambia.
  it('un request que trae su sucursal la conserva, y los demás siguen con la activa', async () => {
    fetchFalso.mockResolvedValue(new Response('{}'))
    const { supabase, setSucursalHeader, getSucursalHeader } = await cargarCliente()

    setSucursalHeader(2)
    await Promise.all([
      supabase.rpc('crear_pedido_idempotente', {}).setHeader('X-Sucursal-ID', '1'),
      supabase.from('pedidos').select('id'),
    ])

    const [, alta] = pedidoA('crear_pedido_idempotente')!
    const [, lista] = pedidoA('/rest/v1/pedidos')!
    expect(new Headers(alta.headers).get('X-Sucursal-ID')).toBe('1')
    expect(new Headers(lista.headers).get('X-Sucursal-ID')).toBe('2')
    expect(getSucursalHeader()).toBe(2)
  })

  // 1600-b1: con `detectSessionInUrl: true`, abrir un link con `#access_token=...` de otro
  // usuario dejaba la sesión del visitante en esa cuenta.
  it('un link con un token en el fragmento no abre ninguna sesión', async () => {
    const payload = btoa(JSON.stringify({ sub: 'otro-usuario', exp: Math.floor(Date.now() / 1000) + 3600 }))
    const jwt = `eyJhbGciOiJIUzI1NiJ9.${payload}.firma`
    fetchFalso.mockImplementation(async () => new Response(JSON.stringify({ id: 'otro-usuario', aud: 'authenticated' })))
    window.history.replaceState(null, '', `/#access_token=${jwt}&refresh_token=r&expires_in=3600&token_type=bearer&type=magiclink`)
    try {
      const { supabase } = await cargarCliente()

      const { data } = await supabase.auth.getSession()

      expect(data.session).toBeNull()
      expect(pedidoA('/auth/v1/user')).toBeUndefined()
      // Y no lo toca: el fragmento queda como vino.
      expect(window.location.hash).toContain('access_token=')
    } finally {
      window.history.replaceState(null, '', '/')
      window.localStorage.clear()
    }
  })

  // 1600-b15: una RPC que contesta «Usuario desactivado» le pide a useAuth que revalide el perfil.
  describe('una RPC que rechaza con «Usuario desactivado»', () => {
    it('pide revalidar el perfil, y el error le llega igual a quien llamó', async () => {
      const pedidos = vi.fn()
      window.addEventListener('perfil:revalidar', pedidos)
      try {
        fetchFalso.mockResolvedValue(new Response(
          JSON.stringify({ code: 'P0001', message: 'Usuario desactivado', details: null, hint: null }),
          { status: 400 },
        ))
        const { supabase } = await cargarCliente()

        const { error } = await supabase.rpc('crear_pedido_completo', {})

        await vi.waitFor(() => expect(pedidos).toHaveBeenCalledTimes(1))
        expect(error?.message).toBe('Usuario desactivado')
      } finally {
        window.removeEventListener('perfil:revalidar', pedidos)
      }
    })

    it('otro rechazo no lo pide', async () => {
      const pedidos = vi.fn()
      window.addEventListener('perfil:revalidar', pedidos)
      try {
        fetchFalso.mockResolvedValue(new Response(
          JSON.stringify({ code: 'P0001', message: 'Stock insuficiente', details: null, hint: null }),
          { status: 400 },
        ))
        const { supabase } = await cargarCliente()

        await supabase.rpc('crear_pedido_completo', {})
        await new Promise(r => setTimeout(r, 20))

        expect(pedidos).not.toHaveBeenCalled()
      } finally {
        window.removeEventListener('perfil:revalidar', pedidos)
      }
    })
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

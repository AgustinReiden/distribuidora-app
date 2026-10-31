/**
 * Tests de `errorDeSupabase`.
 *
 * Las formas que se prueban NO son inventadas: son las dos que arma
 * `PostgrestBuilder` de supabase-js cuando no se usa `.throwOnError()`. Un test
 * que mockee el error como `new Error(...)` —que es lo que hacía el del modal—
 * pasa en verde con el bug puesto, porque `instanceof Error` sólo da false con
 * el objeto plano de verdad.
 */
import { describe, it, expect, afterEach, vi } from 'vitest'
import { createClient, FunctionsFetchError, FunctionsHttpError, FunctionsRelayError } from '@supabase/supabase-js'
import { errorDeSupabase, esErrorDeJwt, esErrorReintentable, respuestaDeErrorLegible } from './errorDeSupabase'
import { isTransientNetworkError, retryWithBackoff, PlazoDeRedVencido } from './retryWithBackoff'
import { esFalloDeRed } from './falloDeRed'
import { RechazoDeNegocioError } from './rechazoDeNegocio'

const SIN_CONEXION = 'Sin conexión: la baja NO se registró.'

function fingirOnLine(valor: boolean) {
  vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(valor)
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('errorDeSupabase', () => {
  it('convierte el objeto plano de PostgREST en un Error de verdad', () => {
    fingirOnLine(true)
    const e = errorDeSupabase(
      {
        message: 'El stock del producto es 3 y la baja es de 5: dejaria stock negativo',
        details: null,
        hint: null,
        code: 'P0001',
      },
      SIN_CONEXION,
    )

    // Las dos mitades importan: si no es `instanceof Error`, la UI muestra su
    // fallback aunque el mensaje esté bien.
    expect(e).toBeInstanceOf(Error)
    expect(e.message).toMatch(/el stock del producto es 3/i)
  })

  it('conserva el mensaje de permisos del servidor', () => {
    fingirOnLine(true)
    const e = errorDeSupabase(
      { message: 'Acceso denegado: se requiere rol admin', details: '', hint: '', code: '42501' },
      SIN_CONEXION,
    )

    expect(e.message).toBe('Acceso denegado: se requiere rol admin')
  })

  it('traduce el fallo de red a un mensaje que se entiende', () => {
    fingirOnLine(true)
    const e = errorDeSupabase(
      {
        message: 'TypeError: Failed to fetch',
        details: 'TypeError: Failed to fetch',
        hint: '',
        code: '',
      },
      SIN_CONEXION,
    )

    expect(e).toBeInstanceOf(Error)
    expect(e.message).toBe(SIN_CONEXION)
    // "Failed to fetch" en pantalla, en un depósito, no es información.
    expect(e.message).not.toMatch(/failed to fetch/i)
  })

  it('trata el "Load failed" de WebKit igual que el de Chrome', () => {
    fingirOnLine(true)
    const e = errorDeSupabase(
      { message: 'TypeError: Load failed', details: '', hint: '', code: '' },
      SIN_CONEXION,
    )

    expect(e.message).toBe(SIN_CONEXION)
  })

  it('con el equipo offline avisa de la conexión aunque el mensaje no diga nada', () => {
    fingirOnLine(false)
    const e = errorDeSupabase({ message: '', details: '', hint: '', code: '' }, SIN_CONEXION)

    expect(e.message).toBe(SIN_CONEXION)
  })

  it('NO tapa el mensaje del servidor cuando navigator.onLine miente', () => {
    // Un celular con 4G de una barra reporta `onLine: false` con la request ya
    // contestada. El `code` es el discriminante: hubo servidor, hubo respuesta.
    fingirOnLine(false)
    const e = errorDeSupabase(
      { message: 'Acceso denegado: se requiere rol admin', details: '', hint: '', code: '42501' },
      SIN_CONEXION,
    )

    expect(e.message).toBe('Acceso denegado: se requiere rol admin')
  })

  it('deja pasar un Error de verdad sin cambiarle el mensaje', () => {
    fingirOnLine(true)
    const e = errorDeSupabase(new Error('No hay sucursal activa'), SIN_CONEXION)

    expect(e.message).toBe('No hay sucursal activa')
  })

  it('si el servidor contesta con el mensaje vacío, no deja el texto en blanco', () => {
    fingirOnLine(true)
    const e = errorDeSupabase({ message: '', details: '', hint: '', code: 'P0001' }, SIN_CONEXION)

    expect(e.message.trim()).not.toBe('')
    expect(e.code).toBe('P0001')
  })

  describe('lo que la normalización NO puede perder', () => {
    it('conserva code, details y hint del servidor (VistaMisEntregas lee .code)', () => {
      fingirOnLine(true)
      const e = errorDeSupabase(
        { message: 'Acceso denegado', details: 'd', hint: 'h', code: '42501' },
        SIN_CONEXION,
      ) as Error & { code?: string; details?: string; hint?: string }

      expect(e.code).toBe('42501')
      expect(e.details).toBe('d')
      expect(e.hint).toBe('h')
    })

    it('un fallo de red normalizado SIGUE siendo transitorio: el reintento no se apaga', () => {
      fingirOnLine(true)
      const e = errorDeSupabase(
        { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' },
        SIN_CONEXION,
      )

      // el mensaje ya no dice 'failed to fetch', pero igual no hubo servidor
      expect(isTransientNetworkError(e)).toBe(true)
      expect(esFalloDeRed(e)).toBe(true)
    })

    it('un error del servidor normalizado NO es transitorio', () => {
      fingirOnLine(true)
      const e = errorDeSupabase(
        { message: 'timeout de statement', details: '', hint: '', code: '57014' },
        SIN_CONEXION,
      )

      expect(isTransientNetworkError(e)).toBe(false)
    })

    it('retryWithBackoff reintenta el error de red normalizado y no el del servidor', async () => {
      fingirOnLine(true)
      const red = vi.fn().mockRejectedValue(
        errorDeSupabase({ message: 'TypeError: Load failed', details: '', hint: '', code: '' }, SIN_CONEXION),
      )
      await expect(
        retryWithBackoff(red, { maxAttempts: 3, initialDelayMs: 1, shouldRetry: isTransientNetworkError }),
      ).rejects.toThrow(SIN_CONEXION)
      expect(red).toHaveBeenCalledTimes(3)

      const srv = vi.fn().mockRejectedValue(
        errorDeSupabase({ message: 'duplicado', details: '', hint: '', code: '23505' }, SIN_CONEXION),
      )
      await expect(
        retryWithBackoff(srv, { maxAttempts: 3, initialDelayMs: 1, shouldRetry: isTransientNetworkError }),
      ).rejects.toThrow('duplicado')
      expect(srv).toHaveBeenCalledTimes(1)
    })
  })
})

/**
 * #1304 (PLT-N7). Sin `code` se reintentaba todo, y un `Error` común no es un
 * fallo del servidor: un bug del queryFn se repetía 3 veces (7 s de pantalla
 * cargando). Las formas de abajo son las que producen las librerías de verdad.
 */
describe('esErrorReintentable', () => {
  it.each([
    ['PGRST301', 'JWT expired'],
    ['PGRST303', 'JWT expired'],
  ])('reintenta un %s: supabase-js renueva el token solo', (code, message) => {
    expect(esErrorReintentable({ message, details: null, hint: null, code })).toBe(true)
  })

  it('no reintenta un Error común: es un bug o un rechazo, no un fallo de red', () => {
    expect(esErrorReintentable(new Error('No se pudo cambiar el tipo de factura'))).toBe(false)
    expect(esErrorReintentable(new TypeError("Cannot read properties of undefined (reading 'map')"))).toBe(false)
    expect(esErrorReintentable(new RechazoDeNegocioError('Compra mínima no alcanzada'))).toBe(false)
  })

  it('reintenta un Error de red de verdad', () => {
    fingirOnLine(true)
    expect(esErrorReintentable(new TypeError('Failed to fetch'))).toBe(true)
    expect(esErrorReintentable(new Error('timed out after 8000ms'))).toBe(true)
    expect(esErrorReintentable(new PlazoDeRedVencido(20_000))).toBe(true)
  })

  it('reintenta lo que ya pasó por errorDeSupabase sin respuesta del servidor', () => {
    fingirOnLine(true)
    const e = errorDeSupabase({ message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' }, SIN_CONEXION)
    expect(esErrorReintentable(e)).toBe(true)
  })

  it('FunctionsHttpError se mira por el status de su `context`', () => {
    expect(esErrorReintentable(new FunctionsHttpError(new Response('{}', { status: 400 })))).toBe(false)
    expect(esErrorReintentable(new FunctionsHttpError(new Response('{}', { status: 401 })))).toBe(false)
    expect(esErrorReintentable(new FunctionsHttpError(new Response('{}', { status: 500 })))).toBe(true)
  })

  it('FunctionsRelayError también, y FunctionsFetchError es un fallo de red', () => {
    fingirOnLine(true)
    expect(esErrorReintentable(new FunctionsRelayError(new Response('', { status: 502 })))).toBe(true)
    expect(esErrorReintentable(new FunctionsFetchError(new TypeError('Failed to fetch')))).toBe(true)
  })

  it('un error de auth se mira por su `status`', () => {
    const conStatus = (status: number) => Object.assign(new Error('auth'), { status })
    expect(esErrorReintentable(conStatus(503))).toBe(true)
    expect(esErrorReintentable(conStatus(422))).toBe(false)
  })

  it('el objeto plano sin code sigue reintentándose: no se sabe qué pasó', () => {
    expect(esErrorReintentable({ message: '<html>502 Bad Gateway</html>' })).toBe(true)
  })

  it('un ErrorDeSupabase sin code que no es de red es una respuesta: no se repite', () => {
    fingirOnLine(true)
    expect(esErrorReintentable(errorDeSupabase({ message: 'Invalid API key' }, SIN_CONEXION))).toBe(false)
  })

  it('reintenta un 55P03: venció el lock_timeout y la transacción se abortó entera', () => {
    const lock = { message: 'canceling statement due to lock timeout', details: null, hint: null, code: '55P03' }
    expect(esErrorReintentable(lock)).toBe(true)
  })

  it('sigue sin reintentar un 57014: repetir la consulta pesada sólo suma carga', () => {
    const lenta = { message: 'canceling statement due to statement timeout', details: null, hint: null, code: '57014' }
    expect(esErrorReintentable(lenta)).toBe(false)
  })

  it('un 5xx normalizado por status se reintenta, un 4xx no', () => {
    expect(esErrorReintentable({ message: 'x', details: null, hint: null, code: 'HTTP_524' })).toBe(true)
    expect(esErrorReintentable({ message: 'x', details: null, hint: null, code: 'HTTP_403' })).toBe(false)
  })
})

describe('esErrorDeJwt', () => {
  it('reconoce los dos códigos de JWT de PostgREST, no otros', () => {
    expect(esErrorDeJwt({ message: 'JWT expired', code: 'PGRST301' })).toBe(true)
    expect(esErrorDeJwt({ message: 'JWT expired', code: 'PGRST303' })).toBe(true)
    expect(esErrorDeJwt({ message: 'permission denied', code: '42501' })).toBe(false)
    expect(esErrorDeJwt(new Error('JWT expired'))).toBe(false)
    expect(esErrorDeJwt(null)).toBe(false)
  })
})

/**
 * #1304 (PLT-N5). Se prueba con el cliente real: lo que importa es el `error` que
 * arma postgrest-js con la respuesta, y es ahí donde un `{ message: <html> }` no
 * trae ni `code` ni `status`.
 */
describe('respuestaDeErrorLegible', () => {
  const html524 = '<!DOCTYPE html><html><head><title>A timeout occurred | 524</title></head><body>Error code 524</body></html>'

  function clienteQueResponde(responder: () => Response | Promise<Response>) {
    return createClient('https://proyecto.supabase.co', 'anon-key', {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { fetch: (async () => responder()) as typeof fetch },
    })
  }

  function errorDe(status: number, cuerpo: string | null) {
    return clienteQueResponde(() => respuestaDeErrorLegible(new Response(cuerpo, { status })))
      .rpc('crear_pedido_idempotente', {})
  }

  it('sin normalizar, el HTML llega como { message } y sin code: de esto se trata', async () => {
    const { error } = await clienteQueResponde(() => new Response(html524, { status: 524 }))
      .rpc('crear_pedido_idempotente', {})
    expect(error).toEqual({ message: html524 })
  })

  it('un 524 con HTML llega con su status como code y sin el HTML', async () => {
    const { error, status } = await errorDe(524, html524)
    expect(status).toBe(524)
    expect(error?.code).toBe('HTTP_524')
    expect(error?.message).toContain('HTTP 524')
    expect(error?.message).not.toContain('<')
    expect(error?.message).not.toMatch(/timeout/i)
  })

  it('el error que sale de ahí gasta reintentos: hubo servidor, no es de red', async () => {
    fingirOnLine(true)
    const { error } = await errorDe(524, html524)
    const e = errorDeSupabase(error, SIN_CONEXION)

    expect(e.sinServidor).toBe(false)
    expect(isTransientNetworkError(e)).toBe(false)
    expect(e.message).not.toBe(SIN_CONEXION)
  })

  // El arranque de la sesión y la carga de sucursales preguntan otra cosa que la
  // cola: si el servidor dijo que no. Un gateway caído no dijo nada, y tomarlo
  // como respuesta dejaba al usuario "sin sucursal" en vez de usar el caché.
  it('para el arranque es "no se pudo preguntar", aunque la cola le gaste un reintento', async () => {
    fingirOnLine(true)
    const { error } = await errorDe(524, html524)

    expect(esFalloDeRed(error)).toBe(true)
    expect(esFalloDeRed(errorDeSupabase(error, SIN_CONEXION))).toBe(true)
  })

  it('un 4xx sí es una respuesta', async () => {
    fingirOnLine(true)
    const { error } = await errorDe(403, '<html><body>Forbidden</body></html>')
    expect(esFalloDeRed(error)).toBe(false)
  })

  it('un 5xx con JSON de gateway, sin code de PostgREST, también va por status', async () => {
    const { error } = await errorDe(504, JSON.stringify({ message: 'upstream request timeout' }))
    expect(error?.code).toBe('HTTP_504')
    expect(isTransientNetworkError(error)).toBe(false)
  })

  it('un 5xx con code numérico también', async () => {
    const { error } = await errorDe(503, JSON.stringify({ code: 503, message: 'Service Unavailable' }))
    expect(error?.code).toBe('HTTP_503')
  })

  it('un 5xx sin cuerpo no queda como error en blanco', async () => {
    const { error } = await errorDe(502, '')
    expect(error?.code).toBe('HTTP_502')
    expect(error?.message).toContain('HTTP 502')
  })

  it('un 4xx con HTML tampoco deja el HTML en el mensaje', async () => {
    const { error } = await errorDe(403, '<html><body>Forbidden</body></html>')
    expect(error?.code).toBe('HTTP_403')
    expect(error?.message).not.toContain('<')
  })

  it('no toca el error de PostgREST: su code y su mensaje son la respuesta', async () => {
    const cuerpo = { message: 'Timed out acquiring connection', details: null, hint: null, code: 'PGRST003' }
    const { error } = await errorDe(503, JSON.stringify(cuerpo))
    expect(error).toEqual(cuerpo)
  })

  it('no toca un RAISE que vuelve con 4xx', async () => {
    const cuerpo = { message: 'Pedido no encontrado', details: null, hint: null, code: 'P0001' }
    const { error } = await errorDe(400, JSON.stringify(cuerpo))
    expect(error).toEqual(cuerpo)
  })

  it('no toca un 4xx con JSON del gateway: su mensaje se entiende', async () => {
    const { error } = await errorDe(401, JSON.stringify({ message: 'Invalid API key', hint: 'Double check' }))
    expect(error).toEqual({ message: 'Invalid API key', hint: 'Double check' })
  })

  it('respeta el 404 vacío que postgrest-js toma como "sin contenido"', async () => {
    const { error, status } = await errorDe(404, '')
    expect(error).toBeNull()
    expect(status).toBe(204)
  })

  it('una respuesta exitosa pasa sin leerse', async () => {
    const res = new Response('{"success":true}', { status: 200 })
    expect(await respuestaDeErrorLegible(res)).toBe(res)
    expect(res.bodyUsed).toBe(false)
  })
})

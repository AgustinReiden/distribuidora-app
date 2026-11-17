/**
 * `logger.error` decidía captureException vs captureMessage mirando sólo
 * `args[0] instanceof Error` (#586). Los 27 call sites reales llaman
 * `logger.error('mensaje', err)` -- el Error va segundo -- así que Sentry
 * recibía un captureMessage del string y perdía el stack. El fix busca un
 * Error en cualquier posición de `args`.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

const captureException = vi.fn()
const captureMessage = vi.fn()

vi.mock('../lib/sentry', () => ({
  captureException: (...args: unknown[]) => captureException(...args),
  captureMessage: (...args: unknown[]) => captureMessage(...args),
}))

async function importLoggerEnProduccion() {
  vi.stubEnv('DEV', false)
  vi.stubEnv('MODE', 'production')
  vi.resetModules()
  const mod = await import('./logger')
  return mod.logger
}

describe('logger.error en producción', () => {
  beforeEach(() => {
    captureException.mockReset()
    captureMessage.mockReset()
  })

  afterEach(() => {
    vi.unstubAllEnvs()
  })

  it("('msg', new Error) → captureException con el Error", async () => {
    const logger = await importLoggerEnProduccion()
    const err = new Error('boom')

    logger.error('contexto', err)

    expect(captureException).toHaveBeenCalledTimes(1)
    expect(captureException.mock.calls[0][0]).toBe(err)
    expect(captureMessage).not.toHaveBeenCalled()
  })

  it("(new Error, 'ctx') → idem", async () => {
    const logger = await importLoggerEnProduccion()
    const err = new Error('boom')

    logger.error(err, 'contexto extra')

    expect(captureException).toHaveBeenCalledTimes(1)
    expect(captureException.mock.calls[0][0]).toBe(err)
    expect(captureMessage).not.toHaveBeenCalled()
  })

  it("('msg') sin Error → captureMessage", async () => {
    const logger = await importLoggerEnProduccion()

    logger.error('algo salió mal')

    expect(captureMessage).toHaveBeenCalledTimes(1)
    expect(captureMessage).toHaveBeenCalledWith('algo salió mal', 'error')
    expect(captureException).not.toHaveBeenCalled()
  })

  /**
   * 1600-b4: supabase-js devuelve el error como objeto plano (`{ message, code, details, hint }`),
   * no como `Error`. Sólo mandaba la etiqueta y se perdían el código y el texto del server.
   */
  it("('msg', errorPlano de supabase) → captureException con la etiqueta y el código", async () => {
    const logger = await importLoggerEnProduccion()

    logger.error('[SucursalContext] Error loading sucursales:', {
      message: 'permission denied for table usuario_sucursales',
      code: '42501',
      details: null,
      hint: null,
    })

    expect(captureMessage).not.toHaveBeenCalled()
    expect(captureException).toHaveBeenCalledTimes(1)
    const [error, contexto] = captureException.mock.calls[0] as [Error, { extra: { codigoSupabase: string } }]
    expect(error).toBeInstanceOf(Error)
    expect(error.message).toContain('[SucursalContext]')
    expect(error.message).toContain('[42501]')
    expect(contexto.extra.codigoSupabase).toBe('42501')
  })

  // Privacidad (#1266): del error plano viaja sólo el código. El `details` de un 23505/23514/23502
  // trae los valores de la fila, y un `message` de RAISE puede nombrar un cliente o un producto.
  it('no manda a Sentry el message, el details ni el hint de un error plano (traen valores de la fila)', async () => {
    const logger = await importLoggerEnProduccion()

    logger.error('Alta de cliente', {
      message: 'duplicate key value violates unique constraint "clientes_nombre_key"',
      code: '23505',
      details: 'Key (nombre_fantasia, direccion)=(Kiosco La Esquina, Calle Falsa 123) already exists.',
      hint: 'Revisá Kiosco La Esquina',
    })

    expect(captureException).toHaveBeenCalledTimes(1)
    const serializado = JSON.stringify(captureException.mock.calls[0].map(a => (a instanceof Error ? a.message : a)))
    expect(serializado).toContain('23505')
    expect(serializado).not.toContain('Kiosco La Esquina')
    expect(serializado).not.toContain('Calle Falsa')
    expect(serializado).not.toContain('duplicate key')
    expect(serializado).not.toContain('Revisá')
  })

  it('un error plano sin código manda la etiqueta con «sin código»', async () => {
    const logger = await importLoggerEnProduccion()

    logger.error('Carga caída', { message: 'TypeError: Failed to fetch', code: '' })

    const [error] = captureException.mock.calls[0] as [Error]
    expect(error.message).toBe('Carga caída [sin código]')
  })

  it('un objeto sin `message` no es un error plano: sigue siendo captureMessage', async () => {
    const logger = await importLoggerEnProduccion()

    logger.error('Estado raro', { codigo: 7 })

    expect(captureMessage).toHaveBeenCalledWith('Estado raro', 'error')
    expect(captureException).not.toHaveBeenCalled()
  })

  /** #1266: el primer argumento a veces es un template con datos del cliente. */
  it('redacta el texto que manda: CUIT, email y URLs con búsquedas', async () => {
    const logger = await importLoggerEnProduccion()

    logger.error('Fallo con 20-12345678-9 en https://x.supabase.co/rest/v1/clientes?or=(cuit.ilike.%2520123%25)', new Error('boom'))
    logger.error('Cliente juan@example.com sin saldo')

    const extra = (captureException.mock.calls[0][1] as { extra: { message: string } }).extra
    expect(extra.message).not.toContain('12345678')
    expect(extra.message).toContain('or=[REDACTED]')
    expect(captureMessage.mock.calls[0][0]).not.toContain('juan@example.com')
  })
})

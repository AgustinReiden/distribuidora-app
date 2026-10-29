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

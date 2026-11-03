/**
 * #1366: cobros, imputaciones y salvedades online tienen plazo de red. Con señal
 * que no pasa datos el request no falla, queda colgado; el plazo lo corta del
 * lado del que llama, y el mensaje tiene que mandar a REVISAR antes de reintentar
 * porque lo que ya llegó al server no se cancela.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { escrituraIdempotente, PLAZO_ESCRITURA_MS } from './escrituraIdempotente'
import { ErrorDeSupabase } from './errorDeSupabase'

const MENSAJE = 'Sin conexión: no se pudo confirmar el pago. Antes de reintentar, revisá la cuenta del cliente.'

const colgada = () => new Promise<never>(() => {})
const errRed = () => new ErrorDeSupabase('sin conexión', { code: '' }, true)
const errServidor = (code: string) => new ErrorDeSupabase('rechazo', { code }, false)

describe('escrituraIdempotente', () => {
  beforeEach(() => { vi.useFakeTimers() })
  afterEach(() => { vi.useRealTimers() })

  it('devuelve lo que contesta la llamada y le pasa el signal', async () => {
    const llamar = vi.fn(async (_signal: AbortSignal) => 'ok')
    await expect(escrituraIdempotente(llamar, MENSAJE)).resolves.toBe('ok')
    expect(llamar.mock.calls[0][0]).toBeInstanceOf(AbortSignal)
  })

  it('una llamada colgada se corta al vencer el plazo y pide revisar antes de reintentar', async () => {
    const llamar = vi.fn(() => colgada())
    const resultado = escrituraIdempotente(llamar, MENSAJE)
    const capturado = resultado.catch((e: unknown) => e)

    await vi.advanceTimersByTimeAsync(PLAZO_ESCRITURA_MS)

    const error = await capturado
    expect(error).toBeInstanceOf(ErrorDeSupabase)
    expect((error as ErrorDeSupabase).message).toBe(MENSAJE)
    expect((error as ErrorDeSupabase).sinServidor).toBe(true)
  })

  it('un plazo vencido no se repite solo: ya se esperó lo que había que esperar', async () => {
    const llamar = vi.fn(() => colgada())
    const capturado = escrituraIdempotente(llamar, MENSAJE).catch((e: unknown) => e)

    await vi.advanceTimersByTimeAsync(PLAZO_ESCRITURA_MS * 5)
    await capturado

    expect(llamar).toHaveBeenCalledTimes(1)
  })

  it('al vencer el plazo aborta el signal que recibió la llamada', async () => {
    let signal!: AbortSignal
    const capturado = escrituraIdempotente((s) => { signal = s; return colgada() }, MENSAJE).catch((e: unknown) => e)

    await vi.advanceTimersByTimeAsync(PLAZO_ESCRITURA_MS)
    await capturado

    expect(signal.aborted).toBe(true)
  })

  it('un fallo de red se repite y el segundo intento entra', async () => {
    const llamar = vi.fn()
      .mockRejectedValueOnce(errRed())
      .mockResolvedValueOnce('ok')
    const resultado = escrituraIdempotente(llamar, MENSAJE)

    await vi.advanceTimersByTimeAsync(10_000)

    await expect(resultado).resolves.toBe('ok')
    expect(llamar).toHaveBeenCalledTimes(2)
  })

  it('un rechazo del servidor no se repite y llega tal cual', async () => {
    const rechazo = errServidor('42501')
    const llamar = vi.fn().mockRejectedValue(rechazo)

    await expect(escrituraIdempotente(llamar, MENSAJE)).rejects.toBe(rechazo)
    expect(llamar).toHaveBeenCalledTimes(1)
  })

  // Decisión de #1366: es idempotente, así que repetirlo sería seguro, pero el
  // gateway contestó y el server pudo seguir con la transacción: se avisa de una.
  it('un 5xx de gateway no se repite', async () => {
    const gateway = errServidor('HTTP_524')
    const llamar = vi.fn().mockRejectedValue(gateway)

    await expect(escrituraIdempotente(llamar, MENSAJE)).rejects.toBe(gateway)
    expect(llamar).toHaveBeenCalledTimes(1)
  })

  it('sin reintentar (RPC sin client_request_id) hace un solo intento aunque sea de red', async () => {
    const llamar = vi.fn().mockRejectedValue(errRed())

    await expect(escrituraIdempotente(llamar, MENSAJE, { reintentar: false })).rejects.toBeInstanceOf(ErrorDeSupabase)
    expect(llamar).toHaveBeenCalledTimes(1)
  })

  it('sin reintentar también tiene plazo', async () => {
    const capturado = escrituraIdempotente(() => colgada(), MENSAJE, { reintentar: false }).catch((e: unknown) => e)

    await vi.advanceTimersByTimeAsync(PLAZO_ESCRITURA_MS)

    expect(((await capturado) as ErrorDeSupabase).message).toBe(MENSAJE)
  })
})

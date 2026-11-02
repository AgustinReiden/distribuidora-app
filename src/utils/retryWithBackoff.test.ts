/**
 * Tests de `retryWithBackoff` / `isTransientNetworkError`.
 *
 * EL INCIDENTE
 * ------------
 * Toda esta capa era código muerto en runtime. `isTransientNetworkError`
 * arrancaba con `if (!(err instanceof Error)) return false`, y supabase-js **no
 * lanza Error**: `PostgrestError` sólo se instancia con `.throwOnError()`, que
 * no se usa en ningún lado del repo. Sin él, un fallo de red vuelve como objeto
 * plano `{ message: "TypeError: Failed to fetch", details, hint, code: '' }`.
 *
 * Resultado: `shouldRetry` devolvía false justo para el caso que motivó el
 * helper. Los 5 call sites (4 de cobro en `usePagos`, 1 de salvedad) hacían un
 * único intento; los 3 intentos con backoff nunca ocurrieron. El chofer perdía
 * el cobro al primer blip de red, que en la calle es la condición normal.
 *
 * El fix no fue sacar el guard sino cambiar el discriminante: lo que no se debe
 * reintentar es un error SEMÁNTICO del servidor (23505, 42501, PGRST203) —
 * reintentarlo no cambia nada— y esos se reconocen por el `code`, no por el
 * tipo. Los de red traen `code: ''`.
 *
 * El caso central de este archivo es el objeto plano: es exactamente lo que
 * ningún test cubría.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { retryWithBackoff, isTransientNetworkError, conPlazoDeRed, PlazoDeRedVencido } from './retryWithBackoff'

/** Lo que supabase-js devuelve realmente ante un fallo de red. */
const errorDeRedDeSupabase = {
  message: 'TypeError: Failed to fetch',
  details: 'TypeError: Failed to fetch',
  hint: '',
  code: '',
}

/** Lo que devuelve ante un error semántico de Postgres. */
const errorSemantico = {
  message: 'duplicate key value violates unique constraint "idx_pagos_client_request_id"',
  details: null,
  hint: null,
  code: '23505',
}

describe('isTransientNetworkError', () => {
  it('reconoce el objeto plano de supabase-js — el caso que estaba roto', () => {
    expect(isTransientNetworkError(errorDeRedDeSupabase)).toBe(true)
  })

  it('reconoce "Load failed" de Safari/WebKit como objeto plano', () => {
    expect(isTransientNetworkError({ message: 'TypeError: Load failed', code: '' })).toBe(true)
  })

  it('sigue reconociendo un Error nativo', () => {
    expect(isTransientNetworkError(new TypeError('Failed to fetch'))).toBe(true)
    expect(isTransientNetworkError(new Error('Network request failed'))).toBe(true)
    expect(isTransientNetworkError(new Error('timeout of 30000ms exceeded'))).toBe(true)
  })

  it('NO reintenta errores semánticos de Postgres: reintentar no cambia nada', () => {
    expect(isTransientNetworkError(errorSemantico)).toBe(false)
    expect(isTransientNetworkError({ message: 'permiso denegado', code: '42501' })).toBe(false)
    // El que rompió "Armar ruta" en prod por un embed ambiguo.
    expect(isTransientNetworkError({ message: 'ambiguous embed', code: 'PGRST203' })).toBe(false)
  })

  it('no confunde un mensaje cualquiera con un problema de red', () => {
    expect(isTransientNetworkError({ message: 'stock insuficiente', code: '' })).toBe(false)
    expect(isTransientNetworkError(new Error('El pedido ya esta cancelado'))).toBe(false)
    expect(isTransientNetworkError(null)).toBe(false)
    expect(isTransientNetworkError(undefined)).toBe(false)
  })
})

describe('retryWithBackoff', () => {
  it('reintenta hasta que sale bien y devuelve el resultado', async () => {
    const fn = vi
      .fn()
      .mockRejectedValueOnce(errorDeRedDeSupabase)
      .mockResolvedValueOnce('cobrado')

    const res = await retryWithBackoff(fn, {
      shouldRetry: isTransientNetworkError,
      initialDelayMs: 1,
    })

    expect(res).toBe('cobrado')
    expect(fn).toHaveBeenCalledTimes(2)
  })

  it('hace los 3 intentos ante red mala persistente y recién ahí propaga', async () => {
    const fn = vi.fn().mockRejectedValue(errorDeRedDeSupabase)

    await expect(
      retryWithBackoff(fn, { shouldRetry: isTransientNetworkError, initialDelayMs: 1 }),
    ).rejects.toBe(errorDeRedDeSupabase)

    // Antes del fix esto valía 1: el bug entero en un número.
    expect(fn).toHaveBeenCalledTimes(3)
  })

  it('con un error semántico corta al primer intento', async () => {
    const fn = vi.fn().mockRejectedValue(errorSemantico)

    await expect(
      retryWithBackoff(fn, { shouldRetry: isTransientNetworkError, initialDelayMs: 1 }),
    ).rejects.toBe(errorSemantico)

    expect(fn).toHaveBeenCalledTimes(1)
  })

  it('respeta maxAttempts', async () => {
    const fn = vi.fn().mockRejectedValue(errorDeRedDeSupabase)

    await expect(
      retryWithBackoff(fn, {
        shouldRetry: isTransientNetworkError,
        initialDelayMs: 1,
        maxAttempts: 5,
      }),
    ).rejects.toBe(errorDeRedDeSupabase)

    expect(fn).toHaveBeenCalledTimes(5)
  })
})

/**
 * #1304 (PLT-N5). `postgrest-js` deja el cuerpo de un error sin JSON en
 * `message`, sin `code`: si el cuerpo decía "timeout", el texto lo volvía un
 * fallo de red, y un fallo de red no gasta reintentos de la cola (#1264). Lo que
 * distingue una respuesta de un fallo de red es la clave `code`: el `catch` del
 * fetch la pone en '' y una respuesta sin JSON de PostgREST no la trae.
 */
describe('isTransientNetworkError ante una respuesta sin code', () => {
  const html524 = '<!DOCTYPE html><html><head><title>A timeout occurred | 524</title></head><body>Error code 524</body></html>'

  it('el HTML de un gateway no es un fallo de red aunque diga "timeout"', () => {
    expect(isTransientNetworkError({ message: html524 })).toBe(false)
  })

  it('un JSON de gateway tampoco', () => {
    expect(isTransientNetworkError({ message: 'upstream request timeout' })).toBe(false)
  })

  it('tampoco cuando ya pasó por errorDeSupabase', () => {
    const normalizado = Object.assign(new Error('upstream request timeout'), { sinServidor: false })
    expect(isTransientNetworkError(normalizado)).toBe(false)
  })
})

describe('conPlazoDeRed', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  const colgado = () => new Promise<never>(() => {})

  it('un intento colgado vence como fallo de red, y antes del plazo no', async () => {
    const intento = conPlazoDeRed(colgado, 20_000)
    const resultado = vi.fn()
    intento.then(resultado, resultado)

    await vi.advanceTimersByTimeAsync(19_999)
    expect(resultado).not.toHaveBeenCalled()

    await vi.advanceTimersByTimeAsync(1)
    const error = resultado.mock.calls[0][0]
    expect(error).toBeInstanceOf(PlazoDeRedVencido)
    expect(isTransientNetworkError(error)).toBe(true)
  })

  it('al vencer aborta la señal, para que el request se corte de verdad', async () => {
    let senal!: AbortSignal
    const intento = conPlazoDeRed((s) => {
      senal = s
      return colgado()
    }, 20_000)
    intento.catch(() => {})

    expect(senal.aborted).toBe(false)
    await vi.advanceTimersByTimeAsync(20_000)
    expect(senal.aborted).toBe(true)
  })

  it('gana el plazo aunque el abort haga rechazar al intento en el mismo tick', async () => {
    const intento = conPlazoDeRed(
      (senal) => new Promise<never>((_, reject) => {
        senal.addEventListener('abort', () => reject({ message: 'AbortError', code: '' }))
      }),
      20_000,
    )
    const rechazo = expect(intento).rejects.toBeInstanceOf(PlazoDeRedVencido)
    await vi.advanceTimersByTimeAsync(20_000)
    await rechazo
  })

  it('un intento que termina a tiempo no deja el plazo corriendo', async () => {
    let senal!: AbortSignal
    const valor = await conPlazoDeRed(async (s) => {
      senal = s
      return 'creado'
    }, 20_000)

    expect(valor).toBe('creado')
    await vi.advanceTimersByTimeAsync(60_000)
    expect(senal.aborted).toBe(false)
  })

  it('el rechazo del intento pasa tal cual', async () => {
    const rechazo = { message: 'stock insuficiente', code: 'P0001' }
    await expect(conPlazoDeRed(() => Promise.reject(rechazo), 20_000)).rejects.toBe(rechazo)
  })
})

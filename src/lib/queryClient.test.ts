/**
 * El retry global de mutations miraba `error.status`, que un `PostgrestError`
 * real no tiene (viene con message/details/hint/code) -- así que la guarda de
 * 4xx nunca se activaba y CUALQUIER mutation fallida se reintentaba, incluida
 * una no idempotente cuyo error fue un timeout después de que el INSERT ya
 * había entrado (#576). El fix: `mutations.retry: false` por default: las
 * mutations idempotentes (pagos, mig 167; `crear_pedido_idempotente`)
 * declaran su propio `retry` en su `useMutation`.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import { MutationObserver, onlineManager } from '@tanstack/react-query'
import { FunctionsHttpError } from '@supabase/supabase-js'
import { queryClient } from './queryClient'

/** Lo que supabase-js devuelve realmente: un objeto plano, sin `status`. */
const errorPostgrestReal = {
  message: 'duplicate key value violates unique constraint "idx_pagos_client_request_id"',
  details: null,
  hint: null,
  code: '23505',
}

describe('queryClient.defaultOptions.mutations.retry', () => {
  it('es `false`: no reintenta ni siquiera ante un PostgrestError real (sin `status`)', () => {
    const retry = queryClient.getDefaultOptions().mutations?.retry
    expect(retry).toBe(false)
    expect('status' in errorPostgrestReal).toBe(false)

    // Con el predicado viejo `(failureCount, error) => ...`, este mismo error
    // caía al `return failureCount < 2` y se reintentaba: exactamente el bug.
    // Con `retry: false` no hay ambigüedad posible.
  })

  it('no toca `queries.retry`', () => {
    const retryQueries = queryClient.getDefaultOptions().queries?.retry
    expect(typeof retryQueries).toBe('function')
  })
})

/**
 * El mismo malentendido que #576, del lado de las queries (#1265): la guarda
 * miraba `error.status`, así que un error permanente del servidor se
 * reintentaba 3 veces (1 + 2 + 4 s) antes de mostrarse. Ahora se mira `code`.
 */
describe('queryClient.defaultOptions.queries.retry', () => {
  const retry = queryClient.getDefaultOptions().queries?.retry as (n: number, e: unknown) => boolean
  const plano = (code: string, message = 'x') => ({ message, details: null, hint: null, code })

  it.each([
    ['42501', 'permission denied for table pagos'],
    ['PGRST201', 'Could not embed because more than one relationship was found'],
    ['PGRST203', 'Could not choose the best candidate function'],
    ['22P02', 'invalid input syntax for type bigint'],
    ['P0001', 'Pedido no encontrado'],
  ])('no reintenta un %s: es una respuesta, no un fallo', (code, message) => {
    expect(retry(0, plano(code, message))).toBe(false)
  })

  it('reintenta un deadlock (40P01): la transacción se abortó entera', () => {
    expect(retry(0, plano('40P01', 'deadlock detected'))).toBe(true)
    expect(retry(2, plano('40P01', 'deadlock detected'))).toBe(true)
    expect(retry(3, plano('40P01', 'deadlock detected'))).toBe(false)
  })

  it('reintenta lo que no tuvo servidor: fallo de red y 502 sin JSON', () => {
    expect(retry(0, plano('', 'TypeError: Failed to fetch'))).toBe(true)
    expect(retry(0, { message: '<html>502 Bad Gateway</html>' })).toBe(true)
    expect(retry(0, plano('PGRST003', 'Timed out acquiring connection from connection pool'))).toBe(true)
  })

  it('no reintenta un 4xx que sí trae `status` (auth)', () => {
    expect(retry(0, { message: 'invalid JWT', status: 401 })).toBe(false)
  })

  // #1304: el error plano de PostgREST no trae `status`, así que la guarda de 4xx
  // de arriba no lo ve; da tiempo a que supabase-js renueve el token.
  it('reintenta un JWT vencido hasta el tope: se renueva solo', () => {
    const jwt = plano('PGRST301', 'JWT expired')
    expect(retry(0, jwt)).toBe(true)
    expect(retry(3, jwt)).toBe(false)
  })

  it('no reintenta un Error común: un bug del queryFn no se arregla repitiéndolo', () => {
    expect(retry(0, new TypeError("Cannot read properties of undefined (reading 'map')"))).toBe(false)
  })

  it('un FunctionsHttpError 4xx no se reintenta, y uno 5xx sí', () => {
    expect(retry(0, new FunctionsHttpError(new Response('{}', { status: 400 })))).toBe(false)
    expect(retry(0, new FunctionsHttpError(new Response('{}', { status: 503 })))).toBe(true)
  })
})

/**
 * INF-4 (#1563): sin red, una mutation quedaba en pausa sin aviso y se disparaba
 * sola al volver la señal (dos veces si el usuario había reintentado). Ahora se
 * intenta igual y falla, y el que la llamó muestra su error.
 */
describe('queryClient: mutations sin red', () => {
  afterEach(() => {
    onlineManager.setOnline(true)
  })

  it('no quedan en pausa: se intentan, fallan con su error y no se disparan solas al volver la red', async () => {
    queryClient.mount()
    onlineManager.setOnline(false)
    const sinRed = new TypeError('Failed to fetch')
    const mutationFn = vi.fn(async () => { throw sinRed })
    const observador = new MutationObserver(queryClient, { mutationFn })

    await expect(observador.mutate()).rejects.toBe(sinRed)
    expect(mutationFn).toHaveBeenCalledTimes(1)
    expect(observador.getCurrentResult().isPaused).toBe(false)
    expect(observador.getCurrentResult().status).toBe('error')

    onlineManager.setOnline(true)
    await new Promise(r => setTimeout(r, 20))
    expect(mutationFn).toHaveBeenCalledTimes(1)
    queryClient.unmount()
  })

  it('las queries siguen esperando la red: sin señal muestran lo que tenían', () => {
    expect(queryClient.getDefaultOptions().queries?.networkMode).toBeUndefined()
  })
})

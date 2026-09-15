/**
 * El retry global de mutations miraba `error.status`, que un `PostgrestError`
 * real no tiene (viene con message/details/hint/code) -- así que la guarda de
 * 4xx nunca se activaba y CUALQUIER mutation fallida se reintentaba, incluida
 * una no idempotente cuyo error fue un timeout después de que el INSERT ya
 * había entrado (#576). El fix: `mutations.retry: false` por default: las
 * mutations idempotentes (pagos, mig 167; `crear_pedido_idempotente`)
 * declaran su propio `retry` en su `useMutation`.
 */
import { describe, it, expect } from 'vitest'
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

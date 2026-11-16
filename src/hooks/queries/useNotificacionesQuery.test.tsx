/**
 * 1600-b14 (#1600): «no existe» no es lo mismo para una tabla que para una columna.
 *
 * `fetchNotificaciones` devolvía `[]` ante cualquier error con "does not exist": también
 * cuando faltaba una COLUMNA (42703), que es un esquema roto y tiene que verse como error,
 * no como una campana vacía.
 *
 * INF-2: la campana se sondea cada 60 s y ya muestra su propio error; no suma un aviso global
 * por cada intento (`meta.silentError`).
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const { respuesta } = vi.hoisted(() => ({
  respuesta: { value: { data: null as unknown, error: null as unknown } },
}))

vi.mock('../supabase/base', () => ({
  supabase: {
    from: () => ({
      select: () => ({
        order: () => ({ limit: async () => respuesta.value }),
      }),
    }),
    rpc: vi.fn(),
  },
}))
vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ perfil: { id: 'u1' }, isOnline: true }),
}))

import { esTablaDeNotificacionesInexistente, useNotificacionesQuery } from './useNotificacionesQuery'

function montar() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return { qc, ...renderHook(() => useNotificacionesQuery(), { wrapper }) }
}

describe('1600-b14: tabla que no existe vs columna que falta', () => {
  beforeEach(() => {
    respuesta.value = { data: null, error: null }
  })

  it('reconoce la tabla inexistente por su código, no por el texto', () => {
    expect(esTablaDeNotificacionesInexistente({ code: '42P01', message: 'relation "notificaciones" does not exist' })).toBe(true)
    expect(esTablaDeNotificacionesInexistente({ code: 'PGRST205', message: "Could not find the table 'public.notificaciones'" })).toBe(true)
    expect(esTablaDeNotificacionesInexistente({ code: '42703', message: 'column notificaciones.leida_at does not exist' })).toBe(false)
    expect(esTablaDeNotificacionesInexistente({ message: 'something does not exist' })).toBe(false)
  })

  it('sin la tabla, la campana queda vacía y no es un error', async () => {
    respuesta.value = { data: null, error: { code: '42P01', message: 'relation "public.notificaciones" does not exist' } }
    const { result } = montar()

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data).toEqual([])
  })

  it('si falta una columna, es un error: no se disfraza de lista vacía', async () => {
    respuesta.value = { data: null, error: { code: '42703', message: 'column notificaciones.leida_at does not exist' } }
    const { result } = montar()

    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(result.current.data).toBeUndefined()
  })

  it('la consulta de la campana va con meta.silentError (INF-2)', async () => {
    respuesta.value = { data: [], error: null }
    const { qc, result } = montar()
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(qc.getQueryCache().find({ queryKey: ['notificaciones'] })?.meta).toEqual({ silentError: true })
  })
})

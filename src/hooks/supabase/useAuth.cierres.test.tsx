/**
 * Los cierres de sesión que no son el botón «Salir» (1600-b6 y 1600-b7, #1600).
 *
 * b6: el cierre por inactividad disparaba un evento que nadie escuchaba; ahora deja el motivo
 * para que el login lo diga.
 * b7: `signOutLocal` (perfil que no existe, refresh fallido, error del arranque) dejaba en el
 * teléfono el caché, las rutas y lo guardado del usuario que sale; ahora corre la misma
 * limpieza que el logout.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, renderHook, waitFor } from '@testing-library/react'

const { mockSupabase, queryClientClear, olvidarTodasLasRutas, limpiarCachesDeLectura } = vi.hoisted(() => ({
  queryClientClear: vi.fn(),
  olvidarTodasLasRutas: vi.fn(),
  limpiarCachesDeLectura: vi.fn().mockResolvedValue(undefined),
  mockSupabase: {
    auth: { getSession: vi.fn(), signInWithPassword: vi.fn(), signOut: vi.fn(), refreshSession: vi.fn(), onAuthStateChange: vi.fn() },
    from: vi.fn(),
  },
}))
vi.mock('./base', () => ({ supabase: mockSupabase }))
vi.mock('../../lib/queryClient', () => ({ queryClient: { clear: queryClientClear } }))
vi.mock('../../lib/rutaOfflineCache', () => ({ olvidarRuta: vi.fn(), olvidarTodasLasRutas }))
vi.mock('../../lib/offlineDb', () => ({ limpiarCachesDeLectura }))
vi.mock('../../contexts/SucursalContext', () => ({ SUCURSAL_STORAGE_KEY: 'distribuidora_sucursal_activa' }))

import { AuthProvider, useAuth } from './useAuth'
import { leerAvisoDeCierre, olvidarAvisoDeCierre } from '../../utils/avisoDeCierreDeSesion'

type Emisor = (evento: string, sesion: unknown) => void

const A = { id: 'user-A', email: 'a@x.com' }
const perfilDe = (id: string) => ({ id, nombre: id, email: `${id}@x.com`, rol: 'admin', activo: true })

let emitir: Emisor | null = null
let hayPerfil = true

function preparar() {
  vi.clearAllMocks()
  localStorage.clear()
  olvidarAvisoDeCierre()
  hayPerfil = true
  mockSupabase.auth.getSession.mockResolvedValue({ data: { session: { user: A } } })
  mockSupabase.auth.signOut.mockResolvedValue({ error: null })
  mockSupabase.auth.onAuthStateChange.mockImplementation((f: Emisor) => {
    emitir = f
    return { data: { subscription: { unsubscribe: vi.fn() } } }
  })
  mockSupabase.from.mockImplementation(() => ({
    select: () => ({
      eq: (_c: string, id: string) => ({ maybeSingle: async () => ({ data: hayPerfil ? perfilDe(id) : null, error: null }) }),
    }),
  }))
}

async function sesionDeA() {
  const wrapper = ({ children }: { children: React.ReactNode }) => <AuthProvider>{children}</AuthProvider>
  const hook = renderHook(() => useAuth(), { wrapper })
  await waitFor(() => expect(hook.result.current.perfil?.id).toBe('user-A'))
  return hook
}

describe('1600-b6: cierre por inactividad', () => {
  beforeEach(() => {
    preparar()
    vi.useFakeTimers({ shouldAdvanceTime: true })
  })
  afterEach(() => vi.useRealTimers())

  it('cierra la sesión y deja dicho por qué, para que el login lo muestre', async () => {
    const { result } = await sesionDeA()
    expect(leerAvisoDeCierre()).toBeNull()

    // 8 h de uso sin tocar nada, en ticks de un minuto (como los cuenta useAuth).
    await act(async () => {
      for (let i = 0; i < 8 * 60 + 2; i++) await vi.advanceTimersByTimeAsync(60_000)
    })

    await waitFor(() => expect(result.current.user).toBeNull())
    expect(leerAvisoDeCierre()).toBe('inactividad')
  })
})

describe('1600-b7: signOutLocal limpia lo del usuario que sale', () => {
  beforeEach(preparar)

  it('un perfil que ya no existe cierra la sesión y borra caché, rutas, caches de lectura y lo guardado', async () => {
    const { result } = await sesionDeA()
    localStorage.setItem('notifications:user-A', JSON.stringify([{ id: 1, title: 'Cobro a Kiosco X' }]))
    expect(queryClientClear).not.toHaveBeenCalled()

    hayPerfil = false
    await act(async () => {
      emitir?.('USER_UPDATED', { user: A })
      await new Promise(r => setTimeout(r, 30))
    })

    await waitFor(() => expect(result.current.user).toBeNull())
    expect(mockSupabase.auth.signOut).toHaveBeenCalled()
    expect(queryClientClear).toHaveBeenCalled()
    expect(olvidarTodasLasRutas).toHaveBeenCalled()
    expect(limpiarCachesDeLectura).toHaveBeenCalled()
    expect(localStorage.getItem('notifications:user-A')).toBeNull()
  })
})

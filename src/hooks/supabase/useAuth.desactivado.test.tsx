/**
 * 1600-b15: un usuario desactivado con el token todavía vivo.
 *
 * El ban de Auth no invalida un access token ya emitido: el server le niega todo (un
 * desactivado no tiene ningún rol), pero el front lo dejaba pasar a una app vacía, sin
 * decirle por qué. Ahora, si el server contesta que su perfil está desactivado, se lo saca y
 * el login se lo explica. Lo que NO es "desactivado" no desloguea a nadie: un perfil que no se
 * pudo leer por la red conserva la sesión.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { act, renderHook, waitFor } from '@testing-library/react'

const { mockSupabase } = vi.hoisted(() => ({
  mockSupabase: {
    auth: { getSession: vi.fn(), signInWithPassword: vi.fn(), signOut: vi.fn(), refreshSession: vi.fn(), onAuthStateChange: vi.fn() },
    from: vi.fn(),
  },
}))
vi.mock('./base', () => ({ supabase: mockSupabase }))
vi.mock('../../lib/queryClient', () => ({ queryClient: { clear: vi.fn() } }))
vi.mock('../../lib/rutaOfflineCache', () => ({ olvidarRuta: vi.fn(), olvidarTodasLasRutas: vi.fn() }))
vi.mock('../../lib/offlineDb', () => ({ limpiarCachesDeLectura: vi.fn().mockResolvedValue(undefined) }))
vi.mock('../../contexts/SucursalContext', () => ({ SUCURSAL_STORAGE_KEY: 'distribuidora_sucursal_activa' }))

import { AuthProvider, useAuth } from './useAuth'
import { leerAvisoDeCierre, olvidarAvisoDeCierre } from '../../utils/avisoDeCierreDeSesion'

const USUARIO = { id: 'user-A', email: 'a@x.com' }
const perfil = (activo: boolean) => ({ id: 'user-A', nombre: 'A', email: 'a@x.com', rol: 'preventista', activo })
const SIN_RED = { message: 'TypeError: Failed to fetch', code: '' }

let respuestaPerfil: () => { data: unknown; error: unknown }

const wrapper = ({ children }: { children: React.ReactNode }) => <AuthProvider>{children}</AuthProvider>

beforeEach(() => {
  vi.clearAllMocks()
  localStorage.clear()
  olvidarAvisoDeCierre()
  respuestaPerfil = () => ({ data: perfil(true), error: null })
  mockSupabase.auth.getSession.mockResolvedValue({ data: { session: { user: USUARIO } } })
  mockSupabase.auth.signOut.mockResolvedValue({ error: null })
  mockSupabase.auth.refreshSession.mockResolvedValue({ data: { session: { user: USUARIO } }, error: null })
  mockSupabase.auth.onAuthStateChange.mockImplementation(() => ({ data: { subscription: { unsubscribe: vi.fn() } } }))
  mockSupabase.from.mockImplementation(() => ({
    select: () => ({ eq: () => ({ maybeSingle: async () => respuestaPerfil() }) }),
  }))
})

describe('un perfil desactivado con la sesión viva (1600-b15)', () => {
  it('lo saca de la app, cierra la sesión local y deja el aviso para el login', async () => {
    respuestaPerfil = () => ({ data: perfil(false), error: null })

    const { result } = renderHook(() => useAuth(), { wrapper })
    await waitFor(() => expect(result.current.loading).toBe(false))

    expect(result.current.user).toBeNull()
    expect(result.current.perfil).toBeNull()
    expect(mockSupabase.auth.signOut).toHaveBeenCalledWith({ scope: 'local' })
    expect(leerAvisoDeCierre()).toBe('desactivado')
  })

  it('no cachea el perfil desactivado ni borra la sesión de otra manera (sin bucle de recargas)', async () => {
    respuestaPerfil = () => ({ data: perfil(false), error: null })

    const { result } = renderHook(() => useAuth(), { wrapper })
    await waitFor(() => expect(result.current.loading).toBe(false))
    // Deja correr cualquier reintento que hubiera.
    await act(async () => { await new Promise(r => setTimeout(r, 50)) })

    expect(localStorage.getItem('distribuidora:ultimo-perfil')).toBeNull()
    // Una sola lectura del perfil, un solo cierre y ningún intento de renovar el token.
    expect(mockSupabase.from).toHaveBeenCalledTimes(1)
    expect(mockSupabase.auth.signOut).toHaveBeenCalledTimes(1)
    expect(mockSupabase.auth.refreshSession).not.toHaveBeenCalled()
  })

  it('el login con un perfil desactivado avisa y no deja entrar', async () => {
    mockSupabase.auth.getSession.mockResolvedValue({ data: { session: null } })
    mockSupabase.auth.signInWithPassword.mockResolvedValue({ data: { user: USUARIO, session: {} }, error: null })
    respuestaPerfil = () => ({ data: perfil(false), error: null })

    const { result } = renderHook(() => useAuth(), { wrapper })
    await waitFor(() => expect(result.current.loading).toBe(false))

    await expect(act(async () => { await result.current.login('a@x.com', 'x') })).rejects.toThrow(/perfil.*desactivado/i)
    expect(result.current.user).toBeNull()
    expect(leerAvisoDeCierre()).toBe('desactivado')
  })

  it('un perfil activo entra normal y no deja aviso', async () => {
    const { result } = renderHook(() => useAuth(), { wrapper })
    await waitFor(() => expect(result.current.perfil?.id).toBe('user-A'))

    expect(result.current.user?.id).toBe('user-A')
    expect(mockSupabase.auth.signOut).not.toHaveBeenCalled()
    expect(leerAvisoDeCierre()).toBeNull()
  })

  it('un perfil que no se pudo leer por la red NO es un desactivado: conserva la sesión', async () => {
    localStorage.setItem('distribuidora:ultimo-perfil', JSON.stringify(perfil(true)))
    respuestaPerfil = () => ({ data: null, error: SIN_RED })

    const { result } = renderHook(() => useAuth(), { wrapper })
    await waitFor(() => expect(result.current.perfil?.id).toBe('user-A'))

    expect(result.current.user?.id).toBe('user-A')
    expect(mockSupabase.auth.signOut).not.toHaveBeenCalled()
    expect(leerAvisoDeCierre()).toBeNull()
  })

  it('sin red y sin perfil cacheado tampoco se desloguea ni se avisa nada', async () => {
    respuestaPerfil = () => ({ data: null, error: SIN_RED })

    const { result } = renderHook(() => useAuth(), { wrapper })
    await waitFor(() => expect(result.current.loading).toBe(false))

    expect(result.current.user?.id).toBe('user-A')
    expect(mockSupabase.auth.signOut).not.toHaveBeenCalled()
    expect(leerAvisoDeCierre()).toBeNull()
  })

  it('un perfil desactivado en el caché no sirve para arrancar sin señal', async () => {
    localStorage.setItem('distribuidora:ultimo-perfil', JSON.stringify(perfil(false)))
    respuestaPerfil = () => ({ data: null, error: SIN_RED })

    const { result } = renderHook(() => useAuth(), { wrapper })
    await waitFor(() => expect(result.current.loading).toBe(false))

    expect(result.current.perfil).toBeNull()
  })

  it('arrancó sin señal con el perfil cacheado y al volver la red el server dice «desactivado»: lo saca', async () => {
    localStorage.setItem('distribuidora:ultimo-perfil', JSON.stringify(perfil(true)))
    respuestaPerfil = () => ({ data: null, error: SIN_RED })
    const { result } = renderHook(() => useAuth(), { wrapper })
    await waitFor(() => expect(result.current.perfil?.id).toBe('user-A'))

    respuestaPerfil = () => ({ data: perfil(false), error: null })
    await act(async () => {
      window.dispatchEvent(new Event('online'))
      await new Promise(r => setTimeout(r, 50))
    })

    await waitFor(() => expect(result.current.user).toBeNull())
    expect(mockSupabase.auth.signOut).toHaveBeenCalledTimes(1)
    expect(leerAvisoDeCierre()).toBe('desactivado')
  })
})

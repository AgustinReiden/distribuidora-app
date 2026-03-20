import React from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, renderHook, waitFor } from '@testing-library/react'

const { maybeSingleMock, unsubscribeMock, mockSupabase } = vi.hoisted(() => {
  const maybeSingleMock = vi.fn()
  const unsubscribeMock = vi.fn()

  return {
    maybeSingleMock,
    unsubscribeMock,
    mockSupabase: {
      auth: {
        getSession: vi.fn(),
        signInWithPassword: vi.fn(),
        signOut: vi.fn(),
        refreshSession: vi.fn(),
        onAuthStateChange: vi.fn()
      },
      from: vi.fn()
    }
  }
})

vi.mock('./base', () => ({
  supabase: mockSupabase
}))

import { AuthProvider, useAuth } from './useAuth'
import { supabase } from './base'

const mockUser = {
  id: 'user-123',
  email: 'test@example.com'
}

const mockPerfil = {
  id: 'user-123',
  nombre: 'Usuario Test',
  email: 'test@example.com',
  rol: 'admin',
  zona: 'norte',
  activo: true
}

function createDeferred() {
  let resolve
  let reject

  const promise = new Promise((res, rej) => {
    resolve = res
    reject = rej
  })

  return { promise, resolve, reject }
}

function Wrapper({ children }) {
  return <AuthProvider>{children}</AuthProvider>
}

describe('useAuth', () => {
  let authCallback = null

  beforeEach(() => {
    vi.clearAllMocks()
    authCallback = null

    maybeSingleMock.mockResolvedValue({ data: null, error: null })

    supabase.from.mockImplementation(() => ({
      select: () => ({
        eq: () => ({
          maybeSingle: maybeSingleMock
        })
      })
    }))

    supabase.auth.getSession.mockResolvedValue({ data: { session: null } })
    supabase.auth.signInWithPassword.mockResolvedValue({
      data: { user: mockUser, session: { user: mockUser } },
      error: null
    })
    supabase.auth.signOut.mockResolvedValue({ error: null })
    supabase.auth.refreshSession.mockResolvedValue({
      data: { session: null },
      error: new Error('refresh failed')
    })
    supabase.auth.onAuthStateChange.mockImplementation((callback) => {
      authCallback = callback
      return { data: { subscription: { unsubscribe: unsubscribeMock } } }
    })
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('deduplica login() y SIGNED_IN del mismo usuario sin hacer signOut', async () => {
    const perfilDeferred = createDeferred()
    maybeSingleMock.mockImplementationOnce(() => perfilDeferred.promise)

    const { result } = renderHook(() => useAuth(), { wrapper: Wrapper })

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })

    let loginPromise

    act(() => {
      loginPromise = result.current.login('test@example.com', 'secret')
    })

    act(() => {
      void authCallback?.('SIGNED_IN', { user: mockUser })
    })

    await waitFor(() => {
      expect(maybeSingleMock).toHaveBeenCalledTimes(1)
      expect(result.current.loading).toBe(true)
    })

    perfilDeferred.resolve({ data: mockPerfil, error: null })

    await act(async () => {
      await loginPromise
    })

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
      expect(result.current.user?.email).toBe(mockUser.email)
      expect(result.current.perfil?.id).toBe(mockPerfil.id)
    })

    expect(supabase.auth.signOut).not.toHaveBeenCalled()
  })

  it('procesa onAuthStateChange fuera del callback para evitar bloqueos de Supabase', async () => {
    maybeSingleMock.mockResolvedValue({ data: mockPerfil, error: null })

    const { result } = renderHook(() => useAuth(), { wrapper: Wrapper })

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })

    const callbackResult = authCallback?.('SIGNED_IN', { user: mockUser })

    expect(callbackResult).toBeUndefined()
    expect(maybeSingleMock).toHaveBeenCalledTimes(0)

    await waitFor(() => {
      expect(maybeSingleMock).toHaveBeenCalledTimes(1)
      expect(result.current.user?.id).toBe(mockUser.id)
      expect(result.current.perfil?.id).toBe(mockPerfil.id)
    })
  })

  it('mantiene loading=true durante bootstrap hasta que termina el perfil', async () => {
    const perfilDeferred = createDeferred()

    supabase.auth.getSession.mockResolvedValue({
      data: { session: { user: mockUser } }
    })
    maybeSingleMock.mockImplementationOnce(() => perfilDeferred.promise)

    const { result } = renderHook(() => useAuth(), { wrapper: Wrapper })

    await waitFor(() => {
      expect(maybeSingleMock).toHaveBeenCalledTimes(1)
    })

    expect(result.current.loading).toBe(true)

    perfilDeferred.resolve({ data: mockPerfil, error: null })

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
      expect(result.current.user?.id).toBe(mockUser.id)
      expect(result.current.perfil?.id).toBe(mockPerfil.id)
    })
  })

  it('sale a login limpio si getSession expira durante bootstrap', async () => {
    vi.useFakeTimers()
    supabase.auth.getSession.mockImplementation(() => new Promise(() => {}))

    const { result } = renderHook(() => useAuth(), { wrapper: Wrapper })

    expect(result.current.loading).toBe(true)

    await act(async () => {
      await vi.advanceTimersByTimeAsync(15001)
    })

    expect(result.current.loading).toBe(false)
    expect(result.current.user).toBeNull()
    expect(result.current.perfil).toBeNull()
    expect(supabase.auth.signOut).toHaveBeenCalledWith({ scope: 'local' })
  })

  it('sale a login limpio si fetchPerfil expira durante bootstrap', async () => {
    vi.useFakeTimers()
    supabase.auth.getSession.mockResolvedValue({
      data: { session: { user: mockUser } }
    })
    maybeSingleMock.mockImplementation(() => new Promise(() => {}))
    supabase.auth.refreshSession.mockResolvedValue({
      data: { session: null },
      error: new Error('refresh failed')
    })

    const { result } = renderHook(() => useAuth(), { wrapper: Wrapper })

    expect(result.current.loading).toBe(true)

    await act(async () => {
      await vi.advanceTimersByTimeAsync(15001)
    })

    expect(result.current.loading).toBe(false)
    expect(result.current.user).toBeNull()
    expect(result.current.perfil).toBeNull()
    expect(supabase.auth.refreshSession).toHaveBeenCalledTimes(1)
    expect(supabase.auth.signOut).toHaveBeenCalledWith({ scope: 'local' })
  })

  it('refresca la sesion expirada y entra si el refresh recupera perfil', async () => {
    supabase.auth.getSession.mockResolvedValue({
      data: { session: { user: mockUser } }
    })
    maybeSingleMock
      .mockResolvedValueOnce({ data: null, error: null })
      .mockResolvedValueOnce({ data: mockPerfil, error: null })
    supabase.auth.refreshSession.mockResolvedValue({
      data: { session: { user: mockUser } },
      error: null
    })

    const { result } = renderHook(() => useAuth(), { wrapper: Wrapper })

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
      expect(result.current.user?.id).toBe(mockUser.id)
      expect(result.current.perfil?.id).toBe(mockPerfil.id)
    })

    expect(supabase.auth.refreshSession).toHaveBeenCalledTimes(1)
    expect(supabase.auth.signOut).not.toHaveBeenCalled()
  })

  it('limpia la sesion cuando el refresh falla', async () => {
    supabase.auth.getSession.mockResolvedValue({
      data: { session: { user: mockUser } }
    })
    maybeSingleMock.mockResolvedValue({ data: null, error: null })
    supabase.auth.refreshSession.mockResolvedValue({
      data: { session: null },
      error: new Error('expired')
    })

    const { result } = renderHook(() => useAuth(), { wrapper: Wrapper })

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
      expect(result.current.user).toBeNull()
      expect(result.current.perfil).toBeNull()
    })

    expect(supabase.auth.signOut).toHaveBeenCalledWith({ scope: 'local' })
  })

  it('logout limpia el estado local aunque falle el signOut remoto', async () => {
    supabase.auth.getSession.mockResolvedValue({
      data: { session: { user: mockUser } }
    })
    maybeSingleMock.mockResolvedValue({ data: mockPerfil, error: null })
    supabase.auth.signOut.mockRejectedValueOnce(new Error('network error'))

    const { result } = renderHook(() => useAuth(), { wrapper: Wrapper })

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
      expect(result.current.user?.id).toBe(mockUser.id)
      expect(result.current.perfil?.id).toBe(mockPerfil.id)
    })

    await act(async () => {
      await result.current.logout()
    })

    expect(result.current.user).toBeNull()
    expect(result.current.perfil).toBeNull()
    expect(supabase.auth.signOut).toHaveBeenCalledWith({ scope: 'local' })
  })

  it('libera la suscripcion al desmontar', () => {
    const { unmount } = renderHook(() => useAuth(), { wrapper: Wrapper })

    unmount()

    expect(unsubscribeMock).toHaveBeenCalled()
  })
})

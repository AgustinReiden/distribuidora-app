import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, act } from '@testing-library/react'

// Mock de supabase con factory inline
vi.mock('./base', () => {
  return {
    supabase: {
      auth: {
        getSession: vi.fn().mockResolvedValue({ data: { session: null } }),
        signInWithPassword: vi.fn(),
        signOut: vi.fn().mockResolvedValue({ error: null }),
        onAuthStateChange: vi.fn().mockReturnValue({
          data: { subscription: { unsubscribe: vi.fn() } }
        })
      },
      from: vi.fn().mockReturnValue({
        select: vi.fn().mockReturnValue({
          eq: vi.fn().mockReturnValue({
            maybeSingle: vi.fn().mockResolvedValue({ data: null })
          })
        })
      })
    }
  }
})

import { AuthProvider, useAuth } from './useAuth'
import { supabase } from './base'

const mockUserData = {
  id: 'user-123',
  email: 'test@example.com'
}

const mockPerfilData = {
  id: 'user-123',
  nombre: 'Usuario Test',
  email: 'test@example.com',
  rol: 'admin',
  zona: 'norte'
}

function TestComponent() {
  const { user, perfil, loading, isAdmin, isPreventista } = useAuth()

  if (loading) return <div data-testid="loading">Cargando...</div>

  return (
    <div>
      <div data-testid="user">{user?.email || 'no user'}</div>
      <div data-testid="perfil">{perfil?.nombre || 'no perfil'}</div>
      <div data-testid="is-admin">{isAdmin ? 'admin' : 'not admin'}</div>
      <div data-testid="is-preventista">{isPreventista ? 'preventista' : 'not preventista'}</div>
    </div>
  )
}

describe('useAuth', () => {
  let authCallback = null

  beforeEach(() => {
    vi.clearAllMocks()
    authCallback = null

    supabase.auth.onAuthStateChange.mockImplementation((callback) => {
      authCallback = callback
      // Trigger INITIAL_SESSION immediately
      setTimeout(() => callback('INITIAL_SESSION', null), 0)
      return { data: { subscription: { unsubscribe: vi.fn() } } }
    })

    supabase.auth.getSession.mockResolvedValue({ data: { session: null } })
  })

  it('muestra no user cuando no hay sesión', async () => {
    render(
      <AuthProvider>
        <TestComponent />
      </AuthProvider>
    )

    await waitFor(() => {
      expect(screen.queryByTestId('loading')).not.toBeInTheDocument()
    }, { timeout: 3000 })

    expect(screen.getByTestId('user')).toHaveTextContent('no user')
  })

  it('actualiza usuario en SIGNED_IN', async () => {
    supabase.from.mockReturnValue({
      select: vi.fn().mockReturnValue({
        eq: vi.fn().mockReturnValue({
          maybeSingle: vi.fn().mockResolvedValue({ data: mockPerfilData })
        })
      })
    })

    render(
      <AuthProvider>
        <TestComponent />
      </AuthProvider>
    )

    await waitFor(() => {
      expect(screen.queryByTestId('loading')).not.toBeInTheDocument()
    }, { timeout: 3000 })

    // Simular SIGNED_IN
    await act(async () => {
      if (authCallback) {
        authCallback('SIGNED_IN', { user: mockUserData })
      }
    })

    await waitFor(() => {
      expect(screen.getByTestId('user')).toHaveTextContent(mockUserData.email)
    })
  })

  it('detecta rol admin correctamente', async () => {
    const adminPerfil = { ...mockPerfilData, rol: 'admin' }

    supabase.from.mockReturnValue({
      select: vi.fn().mockReturnValue({
        eq: vi.fn().mockReturnValue({
          maybeSingle: vi.fn().mockResolvedValue({ data: adminPerfil })
        })
      })
    })

    render(
      <AuthProvider>
        <TestComponent />
      </AuthProvider>
    )

    await waitFor(() => {
      expect(screen.queryByTestId('loading')).not.toBeInTheDocument()
    }, { timeout: 3000 })

    await act(async () => {
      if (authCallback) {
        authCallback('SIGNED_IN', { user: mockUserData })
      }
    })

    await waitFor(() => {
      expect(screen.getByTestId('is-admin')).toHaveTextContent('admin')
    })
  })

  it('limpia estado en SIGNED_OUT', async () => {
    supabase.from.mockReturnValue({
      select: vi.fn().mockReturnValue({
        eq: vi.fn().mockReturnValue({
          maybeSingle: vi.fn().mockResolvedValue({ data: mockPerfilData })
        })
      })
    })

    render(
      <AuthProvider>
        <TestComponent />
      </AuthProvider>
    )

    await waitFor(() => {
      expect(screen.queryByTestId('loading')).not.toBeInTheDocument()
    }, { timeout: 3000 })

    // Login
    await act(async () => {
      if (authCallback) authCallback('SIGNED_IN', { user: mockUserData })
    })

    await waitFor(() => {
      expect(screen.getByTestId('user')).toHaveTextContent(mockUserData.email)
    })

    // Logout
    await act(async () => {
      if (authCallback) authCallback('SIGNED_OUT', null)
    })

    await waitFor(() => {
      expect(screen.getByTestId('user')).toHaveTextContent('no user')
    })
  })

  it('limpia suscripciones al desmontar', async () => {
    const unsubscribeMock = vi.fn()

    supabase.auth.onAuthStateChange.mockReturnValue({
      data: { subscription: { unsubscribe: unsubscribeMock } }
    })

    const { unmount } = render(
      <AuthProvider>
        <TestComponent />
      </AuthProvider>
    )

    unmount()

    expect(unsubscribeMock).toHaveBeenCalled()
  })
})

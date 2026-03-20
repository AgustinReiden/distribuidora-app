/* eslint-disable react-refresh/only-export-components */
import { useState, useEffect, createContext, useContext, useRef, useCallback, ReactNode } from 'react'
import { User } from '@supabase/supabase-js'
import { supabase } from './base'
import { logger } from '../../utils/logger'
import type { RolUsuario } from '../../types'

// Tiempo de inactividad antes de cerrar sesión automáticamente (8 horas)
const INACTIVITY_TIMEOUT_MS = 8 * 60 * 60 * 1000

// Eventos que reinician el timer de inactividad
type ActivityEventName = 'mousedown' | 'keydown' | 'touchstart' | 'scroll' | 'mousemove' | 'click' | 'input' | 'touchmove'
const ACTIVITY_EVENTS: ActivityEventName[] = [
  'mousedown',
  'keydown',
  'touchstart',
  'touchmove',
  'scroll',
  'mousemove',
  'click',
  'input'
]

// Tipo para el perfil de usuario
export interface Perfil {
  id: string;
  nombre: string;
  email: string;
  rol: RolUsuario;
  zona?: string;
  activo: boolean;
  created_at?: string;
  updated_at?: string;
}

// Tipo para el contexto de autenticación
export interface AuthContextValue {
  user: User | null;
  perfil: Perfil | null;
  loading: boolean;
  authReady: boolean;
  login: (email: string, password: string) => Promise<{ user: User | null; session: unknown }>;
  logout: () => Promise<void>;
  isAdmin: boolean;
  isPreventista: boolean;
  isTransportista: boolean;
  zonaUsuario: string | undefined;
}

const AuthContext = createContext<AuthContextValue | null>(null)

interface AuthProviderProps {
  children: ReactNode;
}

export function AuthProvider({ children }: AuthProviderProps) {
  const [user, setUser] = useState<User | null>(null)
  const [perfil, setPerfil] = useState<Perfil | null>(null)
  const [loading, setLoading] = useState(true)

  // Ref para evitar race conditions al verificar el perfil actual
  const perfilRef = useRef<Perfil | null>(null)
  // Track in-flight perfil fetches to avoid duplicates
  const fetchInFlightRef = useRef<string | null>(null)

  // Mantener ref sincronizado con el estado
  perfilRef.current = perfil

  const fetchPerfil = async (userId: string): Promise<boolean> => {
    // Avoid duplicate concurrent fetches for the same user
    if (fetchInFlightRef.current === userId) return false
    fetchInFlightRef.current = userId
    try {
      const { data, error } = await supabase.from('perfiles').select('*').eq('id', userId).maybeSingle()
      if (error) {
        logger.error('[useAuth] Error fetching perfil:', error)
        return false
      }
      if (data) {
        setPerfil(data as Perfil)
        return true
      }
      logger.warn('[useAuth] No perfil found for user:', userId)
      return false
    } catch (err) {
      logger.error('[useAuth] Exception fetching perfil:', err)
      return false
    } finally {
      fetchInFlightRef.current = null
    }
  }

  useEffect(() => {
    let mounted = true

    // Single initialization flow: get session, fetch perfil, THEN set loading=false
    const initAuth = async () => {
      try {
        const { data } = await supabase.auth.getSession()
        if (!mounted) return

        if (data?.session?.user) {
          setUser(data.session.user)
          // AWAIT perfil before setting loading=false
          await fetchPerfil(data.session.user.id)
        }
      } catch (err) {
        logger.error('[useAuth] Error initializing auth:', err)
      } finally {
        if (mounted) setLoading(false)
      }
    }

    void initAuth()

    // Listen for subsequent auth changes (login, logout, token refresh)
    const { data: { subscription } } = supabase.auth.onAuthStateChange(async (event, session) => {
      if (!mounted) return

      if (event === 'SIGNED_IN') {
        if (session?.user) {
          setUser(session.user)
          const currentPerfil = perfilRef.current
          if (!currentPerfil || currentPerfil.id !== session.user.id) {
            await fetchPerfil(session.user.id)
          }
        }
        // setLoading(false) is handled by initAuth for initial load;
        // for subsequent sign-ins (re-login), ensure loading is false
        if (mounted) setLoading(false)
      } else if (event === 'TOKEN_REFRESHED') {
        // Token refreshed — user & perfil already set, nothing to do
        // Only refetch perfil if it's somehow missing
        if (session?.user && !perfilRef.current) {
          await fetchPerfil(session.user.id)
        }
      } else if (event === 'SIGNED_OUT') {
        setUser(null)
        setPerfil(null)
        setLoading(false)
      }
      // INITIAL_SESSION is handled by initAuth, ignore here
    })

    // Safety timer: if initAuth hangs (network down), don't stay on spinner forever
    const safetyTimer = setTimeout(() => {
      if (mounted && loading) {
        logger.warn('[useAuth] Safety timer: forcing loading=false after 5s')
        setLoading(false)
      }
    }, 5000)

    return () => {
      mounted = false
      clearTimeout(safetyTimer)
      subscription.unsubscribe()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const login = async (email: string, password: string) => {
    const { data, error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) throw error
    // Set user and fetch perfil HERE, don't rely solely on onAuthStateChange.
    // This guarantees both user + perfil are set before login() returns,
    // so AppContent renders MainApp immediately instead of flashing LoginScreen.
    if (data.user) {
      setUser(data.user)
      const perfilLoaded = await fetchPerfil(data.user.id)
      if (!perfilLoaded) {
        // Auth succeeded but perfil load failed — clean up and surface error
        await supabase.auth.signOut({ scope: 'local' })
        setUser(null)
        throw new Error('No se pudo cargar el perfil del usuario. Intentá de nuevo.')
      }
    }
    return data
  }

  const logout = useCallback(async () => {
    // Clear local state FIRST to guarantee UI recovery even if signOut fails
    setUser(null)
    setPerfil(null)
    // Use scope: 'local' to avoid server API call that fails with expired tokens
    await supabase.auth.signOut({ scope: 'local' })
  }, [])

  // Session timeout por inactividad (15 minutos)
  useEffect(() => {
    // Solo activar si hay un usuario autenticado
    if (!user) return

    let timeoutId: ReturnType<typeof setTimeout>

    const handleInactivityLogout = () => {
      logger.info('[useAuth] Sesión cerrada por inactividad')
      void logout()
      // Mostrar mensaje al usuario (dispatch custom event)
      window.dispatchEvent(new CustomEvent('session-timeout', {
        detail: { reason: 'inactivity' }
      }))
    }

    const resetInactivityTimer = () => {
      clearTimeout(timeoutId)
      timeoutId = setTimeout(handleInactivityLogout, INACTIVITY_TIMEOUT_MS)
    }

    // Iniciar el timer
    resetInactivityTimer()

    // Agregar listeners de actividad
    ACTIVITY_EVENTS.forEach(event => {
      window.addEventListener(event, resetInactivityTimer, { passive: true })
    })

    // Cleanup
    return () => {
      clearTimeout(timeoutId)
      ACTIVITY_EVENTS.forEach(event => {
        window.removeEventListener(event, resetInactivityTimer)
      })
    }
  }, [user, logout])

  // authReady: true cuando auth terminó de cargar y el perfil está disponible (o no hay usuario)
  const authReady = !loading && (user === null || perfil !== null)

  const value: AuthContextValue = {
    user,
    perfil,
    loading,
    authReady,
    login,
    logout,
    isAdmin: perfil?.rol === 'admin',
    isPreventista: perfil?.rol === 'preventista',
    isTransportista: perfil?.rol === 'transportista',
    zonaUsuario: perfil?.zona
  }

  return (
    <AuthContext.Provider value={value}>
      {children}
    </AuthContext.Provider>
  )
}

export const useAuth = (): AuthContextValue => {
  const context = useContext(AuthContext)
  if (!context) {
    throw new Error('useAuth debe usarse dentro de AuthProvider')
  }
  return context
}

/* eslint-disable react-refresh/only-export-components */
import { useState, useEffect, createContext, useContext, useRef, useCallback, ReactNode } from 'react'
import { User } from '@supabase/supabase-js'
import { supabase } from './base'
import { logger } from '../../utils/logger'
import type { RolUsuario } from '../../types'

// Tiempo de inactividad antes de cerrar sesión automáticamente (15 minutos)
const INACTIVITY_TIMEOUT_MS = 15 * 60 * 1000

// Eventos que reinician el timer de inactividad
const ACTIVITY_EVENTS: (keyof WindowEventMap)[] = [
  'mousedown',
  'keydown',
  'touchstart',
  'scroll',
  'mousemove'
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

  // Mantener ref sincronizado con el estado
  perfilRef.current = perfil

  const fetchPerfil = async (userId: string) => {
    try {
      const { data, error } = await supabase.from('perfiles').select('*').eq('id', userId).maybeSingle()
      if (error) {
        logger.error('[useAuth] Error fetching perfil:', error)
        return
      }
      if (data) setPerfil(data as Perfil)
    } catch (err) {
      logger.error('[useAuth] Exception fetching perfil:', err)
    }
  }

  useEffect(() => {
    let mounted = true
    supabase.auth.getSession().then(({ data }) => {
      if (mounted && data?.session?.user) {
        setUser(data.session.user)
        void fetchPerfil(data.session.user.id)
      }
    }).catch((err) => {
      logger.error('[useAuth] Error getting session:', err)
    })

    const { data: { subscription } } = supabase.auth.onAuthStateChange(async (event, session) => {
      if (!mounted) return
      if (event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED') {
        if (session?.user) {
          setUser(session.user)
          // Usar perfilRef.current para evitar race condition con estado stale
          const currentPerfil = perfilRef.current
          if (!currentPerfil || currentPerfil.id !== session.user.id) {
            void fetchPerfil(session.user.id)
          }
        }
        setLoading(false)
      } else if (event === 'SIGNED_OUT') {
        setUser(null)
        setPerfil(null)
        setLoading(false)
      } else if (event === 'INITIAL_SESSION') {
        setLoading(false)
      }
    })

    const safetyTimer = setTimeout(() => {
      if (mounted && loading) {
        setLoading(false)
      }
    }, 2000)

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
    return data
  }

  const logout = useCallback(async () => {
    const { error } = await supabase.auth.signOut()
    if (error) throw error
    setUser(null)
    setPerfil(null)
  }, [])

  // Session timeout por inactividad (15 minutos)
  useEffect(() => {
    // Solo activar si hay un usuario autenticado
    if (!user) return

    let timeoutId: NodeJS.Timeout

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

  const value: AuthContextValue = {
    user,
    perfil,
    loading,
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

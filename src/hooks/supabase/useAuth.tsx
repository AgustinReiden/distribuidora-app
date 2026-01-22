/* eslint-disable react-refresh/only-export-components */
import { useState, useEffect, createContext, useContext, ReactNode } from 'react'
import { User, AuthError } from '@supabase/supabase-js'
import { supabase } from './base'
import type { RolUsuario } from '../../types'

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

  const fetchPerfil = async (userId: string) => {
    try {
      const { data } = await supabase.from('perfiles').select('*').eq('id', userId).maybeSingle()
      if (data) setPerfil(data as Perfil)
    } catch {
      // Error silenciado
    }
  }

  useEffect(() => {
    let mounted = true
    supabase.auth.getSession().then(({ data }) => {
      if (mounted && data?.session?.user) {
        setUser(data.session.user)
        fetchPerfil(data.session.user.id)
      }
    }).catch(() => {
      // Error silenciado
    })

    const { data: { subscription } } = supabase.auth.onAuthStateChange(async (event, session) => {
      if (!mounted) return
      if (event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED') {
        if (session?.user) {
          setUser(session.user)
          if (!perfil || perfil?.id !== session.user.id) fetchPerfil(session.user.id)
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

  const logout = async () => {
    const { error } = await supabase.auth.signOut()
    if (error) throw error
    setUser(null)
    setPerfil(null)
  }

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

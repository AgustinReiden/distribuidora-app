/* eslint-disable react-refresh/only-export-components */
import { useState, useEffect, createContext, useContext } from 'react'
import { supabase } from './base'

const AuthContext = createContext({})

export function AuthProvider({ children }) {
  const [user, setUser] = useState(null)
  const [perfil, setPerfil] = useState(null)
  const [loading, setLoading] = useState(true)

  const fetchPerfil = async (userId) => {
    try {
      const { data } = await supabase.from('perfiles').select('*').eq('id', userId).maybeSingle()
      if (data) setPerfil(data)
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
  }, [])

  const login = async (email, password) => {
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

  return (
    <AuthContext.Provider value={{
      user,
      perfil,
      loading,
      login,
      logout,
      isAdmin: perfil?.rol === 'admin',
      isPreventista: perfil?.rol === 'preventista',
      isTransportista: perfil?.rol === 'transportista',
      zonaUsuario: perfil?.zona
    }}>
      {children}
    </AuthContext.Provider>
  )
}

export const useAuth = () => useContext(AuthContext)

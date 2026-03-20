/* eslint-disable react-refresh/only-export-components */
import { useState, useEffect, createContext, useContext, useRef, useCallback, ReactNode } from 'react'
import { Session, User } from '@supabase/supabase-js'
import { supabase } from './base'
import { logger } from '../../utils/logger'
import { beginAuthTrace, logAuthEvent, logAuthTiming, resetAuthTrace } from '../../utils/authPerformance'
import type { RolUsuario } from '../../types'

const INACTIVITY_TIMEOUT_MS = 8 * 60 * 60 * 1000
const AUTH_REQUEST_TIMEOUT_MS = 15000

type ActivityEventName =
  | 'mousedown'
  | 'keydown'
  | 'touchstart'
  | 'scroll'
  | 'mousemove'
  | 'click'
  | 'input'
  | 'touchmove'

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

function now(): number {
  return typeof performance !== 'undefined' && typeof performance.now === 'function'
    ? performance.now()
    : Date.now()
}

function withTimeout<T>(promise: PromiseLike<T>, timeoutMs: number, label: string): Promise<T> {
  return new Promise((resolve, reject) => {
    const timeoutId = setTimeout(() => {
      reject(new Error(`${label} timed out after ${timeoutMs}ms`))
    }, timeoutMs)

    Promise.resolve(promise).then(
      (value) => {
        clearTimeout(timeoutId)
        resolve(value)
      },
      (error) => {
        clearTimeout(timeoutId)
        reject(error)
      }
    )
  })
}

export function AuthProvider({ children }: AuthProviderProps) {
  const [user, setUserState] = useState<User | null>(null)
  const [perfil, setPerfilState] = useState<Perfil | null>(null)
  const [bootstrapLoading, setBootstrapLoading] = useState(true)
  const [authTransitionLoading, setAuthTransitionLoading] = useState(false)

  const mountedRef = useRef(true)
  const userIdRef = useRef<string | null>(null)
  const perfilRef = useRef<Perfil | null>(null)
  const bootstrapLoadingRef = useRef(true)
  const perfilRequestsRef = useRef<Map<string, Promise<Perfil | null>>>(new Map())
  const signOutPromiseRef = useRef<Promise<void> | null>(null)
  const authEventTimersRef = useRef<Set<ReturnType<typeof setTimeout>>>(new Set())
  const authEventChainRef = useRef<Promise<void>>(Promise.resolve())

  const setUser = useCallback((nextUser: User | null) => {
    userIdRef.current = nextUser?.id ?? null
    setUserState(nextUser)
  }, [])

  const setPerfil = useCallback((nextPerfil: Perfil | null) => {
    perfilRef.current = nextPerfil
    setPerfilState(nextPerfil)
  }, [])

  perfilRef.current = perfil
  bootstrapLoadingRef.current = bootstrapLoading

  const clearLocalAuthState = useCallback(() => {
    setUser(null)
    setPerfil(null)
  }, [setPerfil, setUser])

  const signOutLocal = useCallback(async (reason: string) => {
    if (signOutPromiseRef.current) {
      return signOutPromiseRef.current
    }

    const signOutPromise = (async () => {
      logger.warn('[useAuth] Clearing local auth state:', reason)
      clearLocalAuthState()
      if (mountedRef.current) {
        setAuthTransitionLoading(false)
      }
      try {
        await supabase.auth.signOut({ scope: 'local' })
      } catch (err) {
        logger.error('[useAuth] Error during local signOut:', err)
      } finally {
        signOutPromiseRef.current = null
      }
    })()

    signOutPromiseRef.current = signOutPromise
    return signOutPromise
  }, [clearLocalAuthState])

  const fetchPerfil = useCallback(async (userId: string): Promise<Perfil | null> => {
    const existingRequest = perfilRequestsRef.current.get(userId)
    if (existingRequest) {
      return existingRequest
    }

    const startedAt = now()

    const request = (async (): Promise<Perfil | null> => {
      try {
        const { data, error } = await withTimeout(
          supabase
            .from('perfiles')
            .select('*')
            .eq('id', userId)
            .maybeSingle(),
          AUTH_REQUEST_TIMEOUT_MS,
          'fetchPerfil'
        )

        if (error) {
          logger.error('[useAuth] Error fetching perfil:', error)
          return null
        }

        if (!data) {
          logger.warn('[useAuth] No perfil found for user:', userId)
          return null
        }

        const nextPerfil = data as Perfil
        if (mountedRef.current && userIdRef.current === userId) {
          setPerfil(nextPerfil)
        }
        return nextPerfil
      } catch (err) {
        logger.error('[useAuth] Exception fetching perfil:', err)
        return null
      } finally {
        perfilRequestsRef.current.delete(userId)
        logAuthTiming('fetchPerfil', now() - startedAt, { userId })
      }
    })()

    perfilRequestsRef.current.set(userId, request)
    return request
  }, [setPerfil])

  const hydrateAuthenticatedUser = useCallback(async (nextUser: User, source: string): Promise<Perfil | null> => {
    setUser(nextUser)
    const nextPerfil = await fetchPerfil(nextUser.id)
    if (nextPerfil) {
      logAuthEvent('perfil-loaded', {
        source,
        userId: nextUser.id,
        rol: nextPerfil.rol
      })
    }
    return nextPerfil
  }, [fetchPerfil, setUser])

  const handleSessionResolved = useCallback(async (
    source: string,
    sessionUser: User | null,
    options: { allowRefresh?: boolean } = {}
  ): Promise<Perfil | null> => {
    if (!sessionUser) {
      clearLocalAuthState()
      return null
    }

    const resolvedPerfil = await hydrateAuthenticatedUser(sessionUser, source)
    if (resolvedPerfil || !options.allowRefresh) {
      return resolvedPerfil
    }

    logger.warn('[useAuth] Perfil fetch failed, attempting session refresh...')
    beginAuthTrace(`${source}:refresh`)

    const refreshStartedAt = now()
    const { data: refreshData, error: refreshError } = await withTimeout(
      supabase.auth.refreshSession(),
      AUTH_REQUEST_TIMEOUT_MS,
      'refreshSession'
    )
    logAuthTiming('refreshSession', now() - refreshStartedAt, { source })

    if (refreshError || !refreshData.session?.user) {
      logger.warn('[useAuth] Session refresh failed, clearing auth state')
      await signOutLocal(`${source}:refresh-failed`)
      return null
    }

    return hydrateAuthenticatedUser(refreshData.session.user, `${source}:refresh`)
  }, [clearLocalAuthState, hydrateAuthenticatedUser, signOutLocal])

  const handleAuthStateChange = useCallback(async (event: string, session: Session | null) => {
    if (!mountedRef.current || event === 'INITIAL_SESSION') {
      return
    }

    const nextUser = session?.user ?? null

    logAuthEvent(`auth-state:${event}`, {
      hasSession: Boolean(nextUser),
      userId: nextUser?.id
    })

    if (event === 'SIGNED_OUT') {
      resetAuthTrace()
      clearLocalAuthState()
      if (mountedRef.current) {
        setAuthTransitionLoading(false)
        setBootstrapLoading(false)
      }
      return
    }

    if (!nextUser) {
      return
    }

    const alreadyHydrated = userIdRef.current === nextUser.id && perfilRef.current?.id === nextUser.id
    if (alreadyHydrated && (event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED')) {
      if (mountedRef.current) {
        setAuthTransitionLoading(false)
      }
      return
    }

    beginAuthTrace(event)
    if (mountedRef.current) {
      setAuthTransitionLoading(true)
    }

    try {
      const resolvedPerfil = await handleSessionResolved(event, nextUser)
      if (!resolvedPerfil) {
        await signOutLocal(`${event}:missing-profile`)
      }
    } catch (err) {
      logger.error(`[useAuth] Error handling auth event ${event}:`, err)
      await signOutLocal(`${event}:handler-error`)
    } finally {
      if (mountedRef.current) {
        setAuthTransitionLoading(false)
      }
    }
  }, [clearLocalAuthState, handleSessionResolved, signOutLocal])

  const scheduleAuthStateChange = useCallback((event: string, session: Session | null) => {
    const timerId = setTimeout(() => {
      authEventTimersRef.current.delete(timerId)

      authEventChainRef.current = authEventChainRef.current
        .catch(() => undefined)
        .then(async () => {
          if (!mountedRef.current) {
            return
          }

          await handleAuthStateChange(event, session)
        })
    }, 0)

    authEventTimersRef.current.add(timerId)
  }, [handleAuthStateChange])

  useEffect(() => {
    mountedRef.current = true
    const authEventTimers = authEventTimersRef.current

    const initAuth = async () => {
      beginAuthTrace('bootstrap')
      const getSessionStartedAt = now()

      try {
        const { data } = await withTimeout(
          supabase.auth.getSession(),
          AUTH_REQUEST_TIMEOUT_MS,
          'getSession'
        )
        logAuthTiming('getSession', now() - getSessionStartedAt)
        if (!mountedRef.current) {
          return
        }

        await handleSessionResolved('initAuth', data?.session?.user ?? null, { allowRefresh: true })
      } catch (err) {
        logger.error('[useAuth] Error initializing auth:', err)
        clearLocalAuthState()
      } finally {
        if (mountedRef.current) {
          setBootstrapLoading(false)
        }
      }
    }

    void initAuth()

    const { data: { subscription } } = supabase.auth.onAuthStateChange((event, session) => {
      scheduleAuthStateChange(event, session)
    })

    const safetyTimer = setTimeout(() => {
      if (mountedRef.current && bootstrapLoadingRef.current) {
        logger.warn('[useAuth] Safety timer: forcing bootstrap loading=false after 5s')
        setBootstrapLoading(false)
      }
    }, 5000)

    return () => {
      mountedRef.current = false
      clearTimeout(safetyTimer)
      authEventTimers.forEach(clearTimeout)
      authEventTimers.clear()
      authEventChainRef.current = Promise.resolve()
      resetAuthTrace()
      subscription.unsubscribe()
    }
  }, [clearLocalAuthState, handleSessionResolved, scheduleAuthStateChange])

  const login = async (email: string, password: string) => {
    beginAuthTrace('login')
    if (mountedRef.current) {
      setAuthTransitionLoading(true)
    }

    try {
      const { data, error } = await withTimeout(
        supabase.auth.signInWithPassword({ email, password }),
        AUTH_REQUEST_TIMEOUT_MS,
        'signInWithPassword'
      )
      if (error) {
        throw error
      }

      if (data.user) {
        const resolvedPerfil = await handleSessionResolved('login', data.user)
        if (!resolvedPerfil) {
          await signOutLocal('login:missing-profile')
          throw new Error('No se pudo cargar el perfil del usuario. Intenta de nuevo.')
        }
      }

      return data
    } finally {
      if (mountedRef.current) {
        setAuthTransitionLoading(false)
      }
    }
  }

  const logout = useCallback(async () => {
    logAuthEvent('logout-requested')
    resetAuthTrace()
    clearLocalAuthState()
    setBootstrapLoading(false)
    setAuthTransitionLoading(false)

    try {
      await supabase.auth.signOut({ scope: 'local' })
    } catch (err) {
      logger.error('[useAuth] Error during logout:', err)
    }
  }, [clearLocalAuthState])

  useEffect(() => {
    if (!user) return

    let timeoutId: ReturnType<typeof setTimeout>

    const handleInactivityLogout = () => {
      logger.info('[useAuth] Session closed due to inactivity')
      void logout()
      window.dispatchEvent(new CustomEvent('session-timeout', {
        detail: { reason: 'inactivity' }
      }))
    }

    const resetInactivityTimer = () => {
      clearTimeout(timeoutId)
      timeoutId = setTimeout(handleInactivityLogout, INACTIVITY_TIMEOUT_MS)
    }

    resetInactivityTimer()

    ACTIVITY_EVENTS.forEach(event => {
      window.addEventListener(event, resetInactivityTimer, { passive: true })
    })

    return () => {
      clearTimeout(timeoutId)
      ACTIVITY_EVENTS.forEach(event => {
        window.removeEventListener(event, resetInactivityTimer)
      })
    }
  }, [user, logout])

  const loading = bootstrapLoading || authTransitionLoading
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

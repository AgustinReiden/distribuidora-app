/* eslint-disable react-refresh/only-export-components */
import { useState, useEffect, createContext, useContext, useRef, useCallback, ReactNode } from 'react'
import { Session, User } from '@supabase/supabase-js'
import { supabase } from './base'
import { logger } from '../../utils/logger'
import { beginAuthTrace, logAuthEvent, logAuthTiming, resetAuthTrace } from '../../utils/authPerformance'
import { queryClient } from '../../lib/queryClient'
import { olvidarRuta, olvidarTodasLasRutas } from '../../lib/rutaOfflineCache'
import { limpiarCachesDeLectura } from '../../lib/offlineDb'
import { SUCURSAL_STORAGE_KEY } from '../../contexts/SucursalContext'
import { esFalloDeRed } from '../../utils/falloDeRed'
import type { RolUsuario } from '../../types'

/**
 * Cuanto aguanta la sesion sin uso. Se cuenta USO REAL: el tiempo que la app
 * paso suspendida o en segundo plano no suma.
 *
 * El bug que arregla: el timer era un unico setTimeout de 8 h. En el iPhone,
 * con la app agregada al inicio, iOS la suspende al cerrarla y el timeout
 * queda pendiente; al volver a abrirla a la manana siguiente el temporizador
 * ya estaba vencido y disparaba el logout en el acto. La usuaria lo vivia como
 * "cada cierto tiempo se me cierra la sesion sola".
 */
const INACTIVITY_TIMEOUT_MS = 8 * 60 * 60 * 1000
/** Cada cuanto se suma inactividad. Fino para no pasarse del plazo por mucho. */
const INACTIVITY_TICK_MS = 60 * 1000
/**
 * Un salto mayor a esto entre dos ticks significa que el navegador congelo los
 * timers (app suspendida, pestania dormida): ese tiempo no es uso, no cuenta.
 */
const INACTIVITY_SALTO_MAX_MS = INACTIVITY_TICK_MS * 3
const AUTH_REQUEST_TIMEOUT_MS = 15000
const AUTH_BOOTSTRAP_FAILSAFE_TIMEOUT_MS = AUTH_REQUEST_TIMEOUT_MS + 3000

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
  isEncargado: boolean;
  isAdminOrEncargado: boolean;
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

function leerSucursalActiva(): number | null {
  try {
    const raw = localStorage.getItem(SUCURSAL_STORAGE_KEY)
    if (!raw) return null
    const id = Number(raw)
    return Number.isFinite(id) ? id : null
  } catch {
    return null
  }
}

/**
 * Borra del dispositivo lo que no tiene que sobrevivir al logout: la ruta
 * del chofer (nombres, direcciones, teléfonos y montos a cobrar en
 * localStorage), el cache de TanStack Query (todo lo que se vio en pantalla:
 * clientes, saldos, pedidos) y los caches de lectura de Dexie.
 *
 * NO toca `pendingOperations` (la cola offline): FE-1 decidió que sobrevive
 * al logout y se oculta por usuario en la UI, no se descarta acá.
 */
function limpiarDatosSensiblesLocales(transportistaId: string | null): void {
  if (transportistaId) {
    olvidarRuta(leerSucursalActiva(), transportistaId)
  }
  // Barrido por si quedó la ruta de otro chofer en un dispositivo compartido.
  olvidarTodasLasRutas()

  queryClient.clear()

  limpiarCachesDeLectura().catch(err => {
    logger.warn('[useAuth] No se pudo limpiar el cache offline:', err)
  })
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

/**
 * Último perfil conocido, para arrancar sin señal.
 *
 * EL BUG QUE ARREGLA: abrir la PWA sin red cerraba la sesión. El token guardado
 * era válido, pero `fetchPerfil` fallaba por red, el refresh también, y el
 * bootstrap terminaba en `signOutLocal` — o sea, se descartaba un token bueno
 * por no poder leer una fila. El preventista quedaba en la pantalla de login,
 * sin señal para volver a entrar, con `MainApp` sin montar: ni la cola offline
 * ni nada de lo que la app tiene para funcionar sin conexión.
 *
 * Mismo criterio que `leerMontoMinimoCacheado` con la política comercial: lo
 * último que se supo es mejor que nada cuando no hay a quién preguntarle.
 */
const CLAVE_PERFIL_CACHEADO = 'distribuidora:ultimo-perfil'

function guardarPerfilCacheado(perfil: Perfil): void {
  try {
    localStorage.setItem(CLAVE_PERFIL_CACHEADO, JSON.stringify(perfil))
  } catch {
    // Sin storage se arranca sin caché: es una mejora, no un requisito.
  }
}

function leerPerfilCacheado(userId: string): Perfil | null {
  try {
    const crudo = localStorage.getItem(CLAVE_PERFIL_CACHEADO)
    if (!crudo) return null
    const perfil = JSON.parse(crudo) as Perfil
    // Del usuario de ESTA sesión y de nadie más: en un teléfono compartido, el
    // perfil cacheado del anterior le daría a este el rol del otro.
    return perfil?.id === userId ? perfil : null
  } catch {
    return null
  }
}

/**
 * Resultado de resolver el perfil. `huboServidor: false` significa que la
 * respuesta nunca llegó — ahí no se toca la sesión.
 */
interface ResultadoPerfil {
  perfil: Perfil | null
  huboServidor: boolean
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
  const perfilRequestsRef = useRef<Map<string, Promise<ResultadoPerfil>>>(new Map())
  /** El perfil que se está mostrando salió del caché y hay que rehidratarlo. */
  const perfilDesdeCacheRef = useRef(false)
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

  const fetchPerfil = useCallback(async (userId: string): Promise<ResultadoPerfil> => {
    const existingRequest = perfilRequestsRef.current.get(userId)
    if (existingRequest) {
      return existingRequest
    }

    const startedAt = now()

    const request = (async (): Promise<ResultadoPerfil> => {
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
          return { perfil: null, huboServidor: !esFalloDeRed(error) }
        }

        if (!data) {
          logger.warn('[useAuth] No perfil found for user:', userId)
          return { perfil: null, huboServidor: true }
        }

        const nextPerfil = data as Perfil
        guardarPerfilCacheado(nextPerfil)
        if (mountedRef.current && userIdRef.current === userId) {
          perfilDesdeCacheRef.current = false
          setPerfil(nextPerfil)
        }
        return { perfil: nextPerfil, huboServidor: true }
      } catch (err) {
        logger.error('[useAuth] Exception fetching perfil:', err)
        // Un timeout tampoco es una respuesta: el servidor no dijo nada.
        return { perfil: null, huboServidor: !esFalloDeRed(err) }
      } finally {
        perfilRequestsRef.current.delete(userId)
        logAuthTiming('fetchPerfil', now() - startedAt, { userId })
      }
    })()

    perfilRequestsRef.current.set(userId, request)
    return request
  }, [setPerfil])

  const hydrateAuthenticatedUser = useCallback(async (nextUser: User, source: string): Promise<ResultadoPerfil> => {
    setUser(nextUser)
    const resultado = await fetchPerfil(nextUser.id)
    if (resultado.perfil) {
      logAuthEvent('perfil-loaded', {
        source,
        userId: nextUser.id,
        rol: resultado.perfil.rol
      })
    }
    return resultado
  }, [fetchPerfil, setUser])

  const handleSessionResolved = useCallback(async (
    source: string,
    sessionUser: User | null,
    options: { allowRefresh?: boolean } = {}
  ): Promise<ResultadoPerfil> => {
    if (!sessionUser) {
      clearLocalAuthState()
      return { perfil: null, huboServidor: true }
    }

    const resultado = await hydrateAuthenticatedUser(sessionUser, source)
    if (resultado.perfil) {
      return resultado
    }

    // SIN SERVIDOR: la sesión no se toca. Renovar el token tampoco va a llegar
    // a ningún lado, y descartarlo dejaría al usuario en el login sin señal
    // para volver a entrar. Se sigue con el último perfil conocido y se
    // rehidrata cuando vuelve la red (ver el listener de 'online').
    if (!resultado.huboServidor) {
      const cacheado = leerPerfilCacheado(sessionUser.id)
      if (cacheado) {
        logger.warn('[useAuth] Sin red: se conserva la sesión con el último perfil conocido')
        logAuthEvent('perfil-desde-cache', { source, userId: sessionUser.id, rol: cacheado.rol })
        perfilDesdeCacheRef.current = true
        setPerfil(cacheado)
        return { perfil: cacheado, huboServidor: false }
      }
      logger.warn('[useAuth] Sin red y sin perfil cacheado; se conserva la sesión igual')
      return { perfil: null, huboServidor: false }
    }

    if (!options.allowRefresh) {
      return resultado
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
      return { perfil: null, huboServidor: true }
    }

    return hydrateAuthenticatedUser(refreshData.session.user, `${source}:refresh`)
  }, [clearLocalAuthState, hydrateAuthenticatedUser, setPerfil, signOutLocal])

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
      const transportistaId = userIdRef.current
      clearLocalAuthState()
      limpiarDatosSensiblesLocales(transportistaId)
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
      const { perfil: resolvedPerfil, huboServidor } = await handleSessionResolved(event, nextUser)
      // Sin perfil Y con el servidor contestando: esta sesión no sirve. Si no
      // hubo servidor, no se concluye nada — se espera a que vuelva la red.
      if (!resolvedPerfil && huboServidor) {
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
        await signOutLocal('initAuth:error')
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
      if (!mountedRef.current || !bootstrapLoadingRef.current) {
        return
      }

      logger.warn(
        `[useAuth] Bootstrap failsafe reached after ${AUTH_BOOTSTRAP_FAILSAFE_TIMEOUT_MS}ms, clearing local auth state`
      )

      void signOutLocal('bootstrap:failsafe-timeout').finally(() => {
        if (mountedRef.current) {
          setBootstrapLoading(false)
        }
      })
    }, AUTH_BOOTSTRAP_FAILSAFE_TIMEOUT_MS)

    return () => {
      mountedRef.current = false
      clearTimeout(safetyTimer)
      authEventTimers.forEach(clearTimeout)
      authEventTimers.clear()
      authEventChainRef.current = Promise.resolve()
      resetAuthTrace()
      subscription.unsubscribe()
    }
  }, [clearLocalAuthState, handleSessionResolved, scheduleAuthStateChange, signOutLocal])

  const login = async (email: string, password: string) => {
    beginAuthTrace('login')
    // NOTE: Don't set authTransitionLoading here. It causes AppContent to
    // show the global spinner which unmounts LoginScreen. If signIn fails,
    // the remounted LoginScreen loses the error state. Instead, we only
    // set it after signIn succeeds (before profile fetch).

    try {
      const { data, error } = await withTimeout(
        supabase.auth.signInWithPassword({ email, password }),
        AUTH_REQUEST_TIMEOUT_MS,
        'signInWithPassword'
      )
      if (error) {
        throw error
      }

      // Only show global loading transition after successful auth
      if (mountedRef.current) {
        setAuthTransitionLoading(true)
      }

      if (data.user) {
        const { perfil: resolvedPerfil } = await handleSessionResolved('login', data.user)
        if (!resolvedPerfil) {
          await signOutLocal('login:missing-profile')
          throw new Error('No se pudo cargar el perfil del usuario. Intenta de nuevo.')
        }
      }

      return data
    } catch (err) {
      // Fire-and-forget: don't block error propagation if signOut hangs
      // (e.g. Supabase unreachable in CI)
      signOutLocal('login:error').catch(() => {})
      throw err
    } finally {
      if (mountedRef.current) {
        setAuthTransitionLoading(false)
      }
    }
  }

  const logout = useCallback(async () => {
    logAuthEvent('logout-requested')
    resetAuthTrace()
    const transportistaId = userIdRef.current
    // El perfil cacheado es para arrancar sin señal, no para sobrevivir a un
    // logout: en un teléfono compartido, el que entra después no tiene por qué
    // ver el rol del anterior. La cola de IndexedDB SÍ sobrevive, a propósito
    // (ver getPendingOperations): borrarla sería perder pedidos.
    try {
      localStorage.removeItem(CLAVE_PERFIL_CACHEADO)
    } catch {
      // Sin storage no hay nada que olvidar.
    }
    perfilDesdeCacheRef.current = false
    clearLocalAuthState()
    setBootstrapLoading(false)
    setAuthTransitionLoading(false)
    limpiarDatosSensiblesLocales(transportistaId)

    try {
      await supabase.auth.signOut({ scope: 'local' })
    } catch (err) {
      logger.error('[useAuth] Error during logout:', err)
    }
  }, [clearLocalAuthState])

  // Vuelve la red: se rehidrata lo que se resolvió a ciegas. Solo si lo que hay
  // es el perfil cacheado (o no hay ninguno): si el del servidor ya se cargó,
  // no hay nada que arreglar y una consulta de más al reconectar es ruido en
  // la peor conexión.
  useEffect(() => {
    if (!user) return

    const rehidratar = (): void => {
      if (!perfilDesdeCacheRef.current && perfilRef.current) return
      void fetchPerfil(user.id)
    }

    window.addEventListener('online', rehidratar)
    return () => window.removeEventListener('online', rehidratar)
  }, [user, fetchPerfil])

  useEffect(() => {
    if (!user) return

    // Inactividad acumulada de uso real. Ver INACTIVITY_TIMEOUT_MS.
    let inactividadMs = 0
    let ultimoTick = Date.now()

    const cerrarPorInactividad = () => {
      logger.info('[useAuth] Session closed due to inactivity')
      void logout()
      window.dispatchEvent(new CustomEvent('session-timeout', {
        detail: { reason: 'inactivity' }
      }))
    }

    const registrarActividad = () => {
      inactividadMs = 0
      ultimoTick = Date.now()
    }

    const intervalId = setInterval(() => {
      const ahora = Date.now()
      const salto = ahora - ultimoTick
      ultimoTick = ahora

      // Timers congelados (app suspendida) o app en segundo plano: no es uso.
      if (salto > INACTIVITY_SALTO_MAX_MS) return
      if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return

      inactividadMs += salto
      if (inactividadMs >= INACTIVITY_TIMEOUT_MS) {
        cerrarPorInactividad()
      }
    }, INACTIVITY_TICK_MS)

    ACTIVITY_EVENTS.forEach(event => {
      window.addEventListener(event, registrarActividad, { passive: true })
    })
    // Volver a la app no es actividad por si sola, pero si marca el arranque
    // del proximo tramo: sin esto el primer tick post-suspension mediria el
    // salto entero contra el reloj viejo.
    document.addEventListener('visibilitychange', registrarActividad)

    return () => {
      clearInterval(intervalId)
      ACTIVITY_EVENTS.forEach(event => {
        window.removeEventListener(event, registrarActividad)
      })
      document.removeEventListener('visibilitychange', registrarActividad)
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
    isEncargado: perfil?.rol === 'encargado',
    isAdminOrEncargado: perfil?.rol === 'admin' || perfil?.rol === 'encargado',
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

import React, { createContext, useContext, useState, useEffect, useCallback, useMemo, ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { supabase, setSucursalHeader } from '../lib/supabase'
import type { UsuarioSucursalDB, RolUsuario } from '../types'
import { logger } from '../utils/logger'
import { esFalloDeRed } from '../utils/falloDeRed'

/** Exportada para que `useAuth` pueda leer la sucursal activa al hacer logout. */
export const SUCURSAL_STORAGE_KEY = 'distribuidora_sucursal_activa'

export interface SucursalInfo {
  id: number
  nombre: string
  rol: RolUsuario // resolved role for this sucursal
  /**
   * Capacidades operativas EXTRA en esta sucursal (tabla perfil_roles, mig 155).
   * Se SUMAN a `rol`; no lo reemplazan. Caso de uso: el preventista de Taco Pozo
   * que acompaña al camión y también reparte.
   */
  rolesExtra: RolUsuario[]
}

export interface SucursalContextValue {
  /**
   * Dueño de la sesión. Vive acá porque es el dato que necesita todo lo que
   * está aislado por usuario **además** de por sucursal — hoy, la cola offline
   * de IndexedDB, que es del teléfono y no de la sesión: sin saber quién está
   * adentro, el usuario B veía y replayaba los pedidos encolados por A.
   */
  userId: string | null
  currentSucursalId: number | null
  currentSucursalNombre: string | null
  currentSucursalRol: RolUsuario | null
  /** Roles extra en la sucursal activa. Ver SucursalInfo.rolesExtra. */
  currentSucursalRolesExtra: RolUsuario[]
  sucursales: SucursalInfo[]
  loading: boolean
  hasMultipleSucursales: boolean
  switchSucursal: (sucursalId: number) => Promise<void>
}

/**
 * Últimas sucursales que el servidor confirmó para este usuario.
 *
 * Este contexto bloquea el arranque: si la consulta falla, `sucursales` queda
 * vacío y la app muestra "sin sucursal asignada". Sin señal eso convertía un
 * arranque offline en un cartel de error, con `MainApp` montado pero inservible
 * — justo el escenario para el que existe toda la maquinaria offline.
 *
 * Solo se usa cuando la consulta falló por RED. Si el servidor contesta que el
 * usuario no tiene sucursales, eso es una respuesta y se respeta: el cartel es
 * correcto (ver C6, que reemplazó el fallback fantasma a la sucursal id=1).
 */
const CLAVE_SUCURSALES_CACHEADAS = 'distribuidora:ultimas-sucursales'

function guardarSucursalesCacheadas(userId: string, sucursales: SucursalInfo[]): void {
  try {
    localStorage.setItem(CLAVE_SUCURSALES_CACHEADAS, JSON.stringify({ userId, sucursales }))
  } catch {
    // Sin storage se arranca sin caché: es una mejora, no un requisito.
  }
}

function leerSucursalesCacheadas(userId: string): SucursalInfo[] | null {
  try {
    const crudo = localStorage.getItem(CLAVE_SUCURSALES_CACHEADAS)
    if (!crudo) return null
    const guardado = JSON.parse(crudo) as { userId?: string; sucursales?: SucursalInfo[] }
    // De ESTE usuario y de nadie más: en un teléfono compartido, las sucursales
    // del anterior le darían a este acceso a un tenant que no es suyo.
    if (guardado?.userId !== userId || !Array.isArray(guardado.sucursales)) return null
    return guardado.sucursales.length > 0 ? guardado.sucursales : null
  } catch {
    return null
  }
}

const SIN_ROLES_EXTRA: RolUsuario[] = []

const SucursalContext = createContext<SucursalContextValue | null>(null)

interface SucursalProviderProps {
  children: ReactNode
  userId: string | null
  globalRol: RolUsuario | null
}

export function SucursalProvider({ children, userId, globalRol }: SucursalProviderProps): React.ReactElement {
  const [sucursales, setSucursales] = useState<SucursalInfo[]>([])
  const [currentSucursalId, setCurrentSucursalId] = useState<number | null>(null)
  const [loading, setLoading] = useState(true)
  const queryClient = useQueryClient()

  // Load usuario_sucursales when userId changes
  useEffect(() => {
    if (!userId || !globalRol) {
      setSucursales([])
      setCurrentSucursalId(null)
      setSucursalHeader(null)
      setLoading(false)
      return
    }

    let cancelled = false

    /** Elige la sucursal activa de una lista ya resuelta y setea el header. */
    const activar = (lista: SucursalInfo[], idPorDefecto?: number) => {
      setSucursales(lista)
      const storedId = localStorage.getItem(SUCURSAL_STORAGE_KEY)
      const storedNum = storedId ? parseInt(storedId, 10) : null
      const activeId = storedNum && lista.some(s => s.id === storedNum)
        ? storedNum
        : (idPorDefecto ?? lista[0].id)
      setCurrentSucursalId(activeId)
      setSucursalHeader(activeId)
      localStorage.setItem(SUCURSAL_STORAGE_KEY, String(activeId))
    }

    /**
     * Sin red: se sigue con las sucursales que el servidor confirmó la última
     * vez. Si el fallo NO es de red, no se toca nada — que el usuario no tenga
     * sucursales es una respuesta válida y el cartel que sigue es correcto.
     */
    const activarDesdeCache = (err: unknown) => {
      if (!esFalloDeRed(err)) return
      const cacheadas = leerSucursalesCacheadas(userId)
      if (!cacheadas) return
      logger.warn('[SucursalContext] Sin red: se usan las últimas sucursales conocidas')
      activar(cacheadas)
    }

    const loadSucursales = async () => {
      setLoading(true)
      try {
        // Los roles extra se piden SIN filtrar por sucursal: la policy
        // perfil_roles_select_propio no depende del header X-Sucursal-ID, que
        // en este punto todavia no esta seteado (se setea mas abajo).
        const [{ data, error }, rolesExtraRes] = await Promise.all([
          supabase
            .from('usuario_sucursales')
            .select('id, usuario_id, sucursal_id, rol, es_default, sucursal:sucursales(id, nombre)')
            .eq('usuario_id', userId),
          supabase
            .from('perfil_roles')
            .select('sucursal_id, rol')
            .eq('usuario_id', userId),
        ])

        // Tolerante a fallo a proposito: este contexto bloquea el arranque de
        // la app. Sin roles extra el usuario entra con su rol primario, que es
        // exactamente el comportamiento previo a la mig 155.
        if (rolesExtraRes.error) {
          logger.warn('[SucursalContext] No se pudieron cargar los roles extra:', rolesExtraRes.error)
        }
        const rolesExtraPorSucursal = new Map<number, RolUsuario[]>()
        for (const fila of (rolesExtraRes.data ?? []) as Array<{ sucursal_id: number; rol: string }>) {
          const acumulado = rolesExtraPorSucursal.get(fila.sucursal_id) ?? []
          acumulado.push(fila.rol as RolUsuario)
          rolesExtraPorSucursal.set(fila.sucursal_id, acumulado)
        }

        if (error) {
          logger.error('[SucursalContext] Error loading sucursales:', error)
          if (!cancelled) {
            activarDesdeCache(error)
            setLoading(false)
          }
          return
        }

        if (!data || data.length === 0) {
          logger.warn('[SucursalContext] Usuario sin sucursales asignadas')
          if (!cancelled) {
            setSucursales([])
            setCurrentSucursalId(null)
            setSucursalHeader(null)
            setLoading(false)
          }
          return
        }

        if (cancelled) return

        const mapped: SucursalInfo[] = (data as unknown as UsuarioSucursalDB[]).map(us => {
          const sucNombre = (us.sucursal as unknown as { id: number; nombre: string })?.nombre ?? `Sucursal ${us.sucursal_id}`
          const resolvedRol: RolUsuario = us.rol === 'mismo' ? globalRol : (us.rol as RolUsuario)
          return {
            id: us.sucursal_id,
            nombre: sucNombre,
            rol: resolvedRol,
            rolesExtra: rolesExtraPorSucursal.get(us.sucursal_id) ?? SIN_ROLES_EXTRA,
          }
        })

        guardarSucursalesCacheadas(userId, mapped)

        // Determine active sucursal: check localStorage first, then es_default, then first
        const defaultEntry = (data as unknown as UsuarioSucursalDB[]).find(us => us.es_default)
        activar(mapped, defaultEntry?.sucursal_id)
      } catch (err) {
        logger.error('[SucursalContext] Exception loading sucursales:', err)
        if (!cancelled) activarDesdeCache(err)
      } finally {
        if (!cancelled) setLoading(false)
      }
    }

    void loadSucursales()

    return () => {
      cancelled = true
    }
  }, [userId, globalRol])

  const switchSucursal = useCallback(async (sucursalId: number) => {
    if (sucursalId === currentSucursalId) return
    if (!userId) return

    try {
      // Call RPC to update es_default in DB
      const { error } = await supabase.rpc('cambiar_sucursal', { p_sucursal_id: sucursalId })
      if (error) {
        logger.error('[SucursalContext] Error switching sucursal:', error)
        return
      }

      setCurrentSucursalId(sucursalId)
      setSucursalHeader(sucursalId)
      localStorage.setItem(SUCURSAL_STORAGE_KEY, String(sucursalId))

      // Invalidate ALL queries so data refetches for new sucursal
      await queryClient.invalidateQueries()
    } catch (err) {
      logger.error('[SucursalContext] Exception switching sucursal:', err)
    }
  }, [currentSucursalId, userId, queryClient])

  const value = useMemo<SucursalContextValue>(() => {
    const currentSucursal = sucursales.find(s => s.id === currentSucursalId)
    return {
      userId,
      currentSucursalId,
      currentSucursalNombre: currentSucursal?.nombre ?? null,
      currentSucursalRol: currentSucursal?.rol ?? globalRol,
      currentSucursalRolesExtra: currentSucursal?.rolesExtra ?? SIN_ROLES_EXTRA,
      sucursales,
      loading,
      hasMultipleSucursales: sucursales.length > 1,
      switchSucursal,
    }
  }, [userId, currentSucursalId, sucursales, loading, globalRol, switchSucursal])

  return (
    <SucursalContext.Provider value={value}>
      {children}
    </SucursalContext.Provider>
  )
}

// eslint-disable-next-line react-refresh/only-export-components
export function useSucursal(): SucursalContextValue {
  const context = useContext(SucursalContext)
  if (!context) {
    throw new Error('useSucursal debe usarse dentro de un SucursalProvider')
  }
  return context
}

export default SucursalContext

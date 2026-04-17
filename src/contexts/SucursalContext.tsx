import React, { createContext, useContext, useState, useEffect, useCallback, useMemo, ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { supabase, setSucursalHeader } from '../lib/supabase'
import type { UsuarioSucursalDB, RolUsuario } from '../types'
import { logger } from '../utils/logger'

const SUCURSAL_STORAGE_KEY = 'distribuidora_sucursal_activa'

export interface SucursalInfo {
  id: number
  nombre: string
  rol: RolUsuario // resolved role for this sucursal
}

export interface SucursalContextValue {
  currentSucursalId: number | null
  currentSucursalNombre: string | null
  currentSucursalRol: RolUsuario | null
  sucursales: SucursalInfo[]
  loading: boolean
  hasMutipleSucursales: boolean
  switchSucursal: (sucursalId: number) => Promise<void>
}

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

    const loadSucursales = async () => {
      setLoading(true)
      try {
        const { data, error } = await supabase
          .from('usuario_sucursales')
          .select('id, usuario_id, sucursal_id, rol, es_default, sucursal:sucursales(id, nombre)')
          .eq('usuario_id', userId)

        if (error) {
          logger.error('[SucursalContext] Error loading sucursales:', error)
          if (!cancelled) setLoading(false)
          return
        }

        if (!data || data.length === 0) {
          logger.warn('[SucursalContext] No sucursales found for user, defaulting to sucursal 1')
          if (!cancelled) {
            const fallback: SucursalInfo = { id: 1, nombre: 'Principal', rol: globalRol }
            setSucursales([fallback])
            setCurrentSucursalId(1)
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
          }
        })

        setSucursales(mapped)

        // Determine active sucursal: check localStorage first, then es_default, then first
        const storedId = localStorage.getItem(SUCURSAL_STORAGE_KEY)
        const storedNum = storedId ? parseInt(storedId, 10) : null
        const defaultEntry = (data as unknown as UsuarioSucursalDB[]).find(us => us.es_default)

        let activeId: number
        if (storedNum && mapped.some(s => s.id === storedNum)) {
          activeId = storedNum
        } else if (defaultEntry) {
          activeId = defaultEntry.sucursal_id
        } else {
          activeId = mapped[0].id
        }

        setCurrentSucursalId(activeId)
        setSucursalHeader(activeId)
        localStorage.setItem(SUCURSAL_STORAGE_KEY, String(activeId))
      } catch (err) {
        logger.error('[SucursalContext] Exception loading sucursales:', err)
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
      currentSucursalId,
      currentSucursalNombre: currentSucursal?.nombre ?? null,
      currentSucursalRol: currentSucursal?.rol ?? globalRol,
      sucursales,
      loading,
      hasMutipleSucursales: sucursales.length > 1,
      switchSucursal,
    }
  }, [currentSucursalId, sucursales, loading, globalRol, switchSucursal])

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

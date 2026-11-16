/**
 * Notificaciones persistentes (DB) para la campanita.
 *
 * Se leen por POLLING (no realtime): el header de sucursal no viaja por
 * websocket y la publicación realtime está vacía, así que polling con TanStack
 * Query es lo robusto. RLS filtra por usuario (auth.uid()).
 */
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useAuthData } from '../../contexts/AuthDataContext'

export interface NotificacionDB {
  id: number
  usuario_id: string
  sucursal_id: number | null
  tipo: string
  titulo: string
  mensaje: string | null
  entidad_tipo: string | null
  entidad_id: number | null
  payload: Record<string, unknown> | null
  leida: boolean
  created_at: string
  leida_at: string | null
}

/**
 * La tabla `notificaciones` no existe (entorno sin la migración): no hay nada que
 * mostrar y no es un error. Se reconoce por el código, NO por el texto "does not
 * exist": Postgres dice lo mismo cuando falta una COLUMNA (42703), y eso es un
 * esquema roto que tiene que verse, no una lista vacía (1600-b14, #1600).
 * 42P01 es «relation does not exist» y PGRST205 «no está en el schema cache».
 */
export function esTablaDeNotificacionesInexistente(error: { code?: string | null; message?: string }): boolean {
  return error.code === '42P01' || error.code === 'PGRST205'
}

async function fetchNotificaciones(): Promise<NotificacionDB[]> {
  const { data, error } = await supabase
    .from('notificaciones')
    .select('*')
    .order('created_at', { ascending: false })
    .limit(30)
  if (error) {
    if (esTablaDeNotificacionesInexistente(error)) return []
    throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar las notificaciones. Revisá la señal e intentá de nuevo.')
  }
  return (data || []) as NotificacionDB[]
}

export function useNotificacionesQuery() {
  const { perfil, isOnline } = useAuthData()
  return useQuery({
    queryKey: ['notificaciones'],
    queryFn: fetchNotificaciones,
    enabled: !!perfil && isOnline !== false,
    refetchInterval: 60_000,
    refetchOnWindowFocus: true,
    staleTime: 30_000,
    // Se sondea cada 60 s: si falla, la campana ya muestra su propio error y no
    // tiene que sumar un aviso global por cada intento (INF-2, #1600).
    meta: { silentError: true },
  })
}

export function useMarcarNotificacionLeidaMutation() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: number) => {
      const { error } = await supabase.rpc('marcar_notificacion_leida', { p_id: id })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la marca de leída. Revisá las notificaciones antes de reintentar, puede haber quedado hecho.')
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['notificaciones'] }),
  })
}

export function useMarcarTodasNotificacionesLeidasMutation() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc('marcar_todas_notificaciones_leidas')
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la marca de leídas. Revisá las notificaciones antes de reintentar, puede haber quedado hecho.')
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['notificaciones'] }),
  })
}

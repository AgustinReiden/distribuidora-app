/**
 * TanStack Query hooks para la vista admin del bot Telegram (Phase 4 task 4.2).
 *
 * Wrappers de las 5 RPCs SECURITY DEFINER definidas en migración 019:
 *   * bot_admin_listar_vinculados()
 *   * bot_admin_audit_log(p_desde, p_hasta, p_tipo, p_perfil_id, p_limit)
 *   * bot_admin_audit_summary(p_desde, p_hasta)
 *   * bot_admin_digests_enviados(p_desde, p_hasta)
 *   * bot_admin_toggle_usuario(p_telegram_user_id, p_activo)
 *
 * Las RPCs gatean por `perfiles.rol = 'admin'`. El frontend además bloquea
 * la ruta a no-admin via Navigate, así que estos hooks NO se montan para
 * usuarios sin permiso. Siguen el patrón de `useUsuariosQuery`.
 */
import {
  useMutation,
  useQuery,
  useQueryClient,
  type UseMutationResult,
  type UseQueryResult,
} from '@tanstack/react-query'
import { supabase } from '../supabase/base'

// =============================================================================
// TYPES
// =============================================================================

export interface BotVinculado {
  telegram_user_id: number
  telegram_username: string | null
  perfil_id: string
  perfil_nombre: string | null
  perfil_email: string | null
  rol: string
  sucursal_id: number | null
  sucursal_nombre: string | null
  vinculado_at: string
  ultimo_uso_at: string | null
  activo: boolean
}

export interface BotAuditEvent {
  id: number
  telegram_user_id: number | null
  perfil_id: string | null
  perfil_nombre: string | null
  rol: string | null
  tipo: 'mensaje' | 'comando' | 'tool_call' | 'respuesta' | 'error' | string
  tool_name: string | null
  parametros: unknown
  resultado_meta: unknown
  texto_usuario: string | null
  texto_bot: string | null
  created_at: string
}

export interface BotAuditPorTipo {
  tipo: string
  count: number
}

export interface BotAuditPorPerfil {
  perfil_id: string
  perfil_nombre: string | null
  count: number
}

export interface BotAuditToolTop {
  tool_name: string
  count: number
}

export interface BotAuditSummary {
  total_eventos: number
  por_tipo: BotAuditPorTipo[]
  por_perfil: BotAuditPorPerfil[]
  tools_top: BotAuditToolTop[]
  errores_recientes: number
}

export interface BotDigestEnviado {
  admin_perfil_id: string
  perfil_nombre: string | null
  sucursal_nombre: string | null
  fecha: string
  sent_at: string
  telegram_user_id: number | null
  status: 'ok' | 'error' | 'skipped' | string
  error_meta: unknown
}

export interface BotAuditFilters {
  desde: string
  hasta: string
  tipo?: string
  perfil_id?: string
  limit?: number
}

export interface BotToggleUsuarioInput {
  telegram_user_id: number
  activo: boolean
}

export interface BotToggleUsuarioResult {
  success: boolean
  telegram_user_id: number
  activo: boolean
}

// =============================================================================
// QUERY KEYS
// =============================================================================

export const botAdminKeys = {
  all: ['bot_admin'] as const,
  vinculados: () => [...botAdminKeys.all, 'vinculados'] as const,
  auditLog: (filters: BotAuditFilters) => [...botAdminKeys.all, 'audit_log', filters] as const,
  auditSummary: (desde: string, hasta: string) =>
    [...botAdminKeys.all, 'audit_summary', desde, hasta] as const,
  digestsEnviados: (desde: string, hasta: string) =>
    [...botAdminKeys.all, 'digests', desde, hasta] as const,
}

// =============================================================================
// FETCHERS
// =============================================================================

async function fetchVinculados(): Promise<BotVinculado[]> {
  const { data, error } = await supabase.rpc('bot_admin_listar_vinculados')
  if (error) throw error
  return (data as BotVinculado[] | null) ?? []
}

async function fetchAuditLog(filters: BotAuditFilters): Promise<BotAuditEvent[]> {
  const { data, error } = await supabase.rpc('bot_admin_audit_log', {
    p_desde: filters.desde,
    p_hasta: filters.hasta,
    p_tipo: filters.tipo ?? null,
    p_perfil_id: filters.perfil_id ?? null,
    p_limit: filters.limit ?? 200,
  })
  if (error) throw error
  return (data as BotAuditEvent[] | null) ?? []
}

async function fetchAuditSummary(desde: string, hasta: string): Promise<BotAuditSummary> {
  const { data, error } = await supabase.rpc('bot_admin_audit_summary', {
    p_desde: desde,
    p_hasta: hasta,
  })
  if (error) throw error
  if (!data || typeof data !== 'object') {
    return {
      total_eventos: 0,
      por_tipo: [],
      por_perfil: [],
      tools_top: [],
      errores_recientes: 0,
    }
  }
  return data as BotAuditSummary
}

async function fetchDigestsEnviados(desde: string, hasta: string): Promise<BotDigestEnviado[]> {
  const { data, error } = await supabase.rpc('bot_admin_digests_enviados', {
    p_desde: desde,
    p_hasta: hasta,
  })
  if (error) throw error
  return (data as BotDigestEnviado[] | null) ?? []
}

async function toggleUsuarioBot(input: BotToggleUsuarioInput): Promise<BotToggleUsuarioResult> {
  const { data, error } = await supabase.rpc('bot_admin_toggle_usuario', {
    p_telegram_user_id: input.telegram_user_id,
    p_activo: input.activo,
  })
  if (error) throw error
  return (data as BotToggleUsuarioResult) ?? {
    success: false,
    telegram_user_id: input.telegram_user_id,
    activo: input.activo,
  }
}

// =============================================================================
// HOOKS
// =============================================================================

/**
 * Hook para listar usuarios vinculados al bot.
 * Solo admin (la RPC valida el rol; el componente además gating la ruta).
 */
export function useBotVinculadosQuery(): UseQueryResult<BotVinculado[], Error> {
  return useQuery<BotVinculado[], Error>({
    queryKey: botAdminKeys.vinculados(),
    queryFn: fetchVinculados,
    staleTime: 60 * 1000,
  })
}

/**
 * Hook para leer el audit log con filtros y paginación implícita (limit).
 */
export function useBotAuditLogQuery(filters: BotAuditFilters): UseQueryResult<BotAuditEvent[], Error> {
  return useQuery<BotAuditEvent[], Error>({
    queryKey: botAdminKeys.auditLog(filters),
    queryFn: () => fetchAuditLog(filters),
    enabled: !!filters.desde && !!filters.hasta,
    staleTime: 30 * 1000,
  })
}

/**
 * Hook para el resumen agregado del audit log.
 */
export function useBotAuditSummaryQuery(
  desde: string,
  hasta: string,
): UseQueryResult<BotAuditSummary, Error> {
  return useQuery<BotAuditSummary, Error>({
    queryKey: botAdminKeys.auditSummary(desde, hasta),
    queryFn: () => fetchAuditSummary(desde, hasta),
    enabled: !!desde && !!hasta,
    staleTime: 60 * 1000,
  })
}

/**
 * Hook para el histórico de digests enviados.
 */
export function useBotDigestsEnviadosQuery(
  desde: string,
  hasta: string,
): UseQueryResult<BotDigestEnviado[], Error> {
  return useQuery<BotDigestEnviado[], Error>({
    queryKey: botAdminKeys.digestsEnviados(desde, hasta),
    queryFn: () => fetchDigestsEnviados(desde, hasta),
    enabled: !!desde && !!hasta,
    staleTime: 60 * 1000,
  })
}

/**
 * Mutation para activar/desactivar un usuario del bot. Invalida el listado de
 * vinculados al éxito.
 */
export function useToggleBotUsuarioMutation(): UseMutationResult<
  BotToggleUsuarioResult,
  Error,
  BotToggleUsuarioInput
> {
  const queryClient = useQueryClient()
  return useMutation<BotToggleUsuarioResult, Error, BotToggleUsuarioInput>({
    mutationFn: toggleUsuarioBot,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: botAdminKeys.vinculados() })
    },
  })
}

/**
 * TanStack Query hooks para la configuración del digest de Telegram.
 *
 * Wrappers de dos RPCs SECURITY DEFINER gateadas por `perfiles.rol = 'admin'`
 * (desde la mig 311 listan y configuran también a los preventistas vinculados):
 *   * bot_admin_listar_config_digest()
 *   * bot_admin_guardar_config_digest(p_perfil_id, p_activo, p_hora_local,
 *                                     p_dias, p_secciones)
 *
 * Mismo patrón que `useBotAdmin`: la ruta ya está gateada a admin, así que
 * estos hooks no se montan para nadie más.
 */
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import {
  useMutation,
  useQuery,
  useQueryClient,
  type UseMutationResult,
  type UseQueryResult,
} from '@tanstack/react-query'
import { supabase } from '../supabase/base'

// El catálogo y los helpers de presentación viven en `utils/` (lógica pura,
// testeable sin el cliente de Supabase). Se re-exportan acá para que el panel
// los importe de un solo lugar.
export {
  DIAS_SEMANA,
  SECCIONES_DIGEST,
  formatHora,
  labelSeccion,
  resumirDias,
  seccionesParaRol,
  type SeccionDigestKey,
} from '../../utils/digestSecciones'

// =============================================================================
// TYPES
// =============================================================================

export interface BotDigestConfig {
  perfil_id: string
  perfil_nombre: string | null
  /** 'admin' o 'preventista' (mig 311). Ausente en respuestas anteriores: admin. */
  rol?: string
  /**
   * Las secciones que la base le deja recibir a esta persona según su rol
   * (`digest_secciones_del_rol`). El panel ofrece sólo éstas.
   */
  secciones_permitidas?: string[]
  telegram_user_id: number
  sucursal_id: number | null
  sucursal_nombre: string | null
  /**
   * false = nunca se guardó una configuración para esta persona y lo que se
   * muestra es el default. El panel lo señala: "sin configurar" no es lo mismo
   * que "eligió esto".
   */
  configurado: boolean
  activo: boolean
  hora_local: number
  dias_semana: number[]
  secciones: string[]
  actualizado_at: string | null
  actualizado_por: string | null
  /** true = es la fila del admin que está mirando el panel (mig 325). Siempre viene primera. */
  es_propio?: boolean
  /**
   * Aviso semanal de clientes atrasados (mig 325). Sólo viene para
   * preventistas (default: activo, 08:00, lunes); null para los admins.
   */
  aviso_atrasados?: AvisoAtrasadosConfig | null
}

export interface AvisoAtrasadosConfig {
  activo: boolean
  hora: number
  dias: number[]
}

export interface GuardarAvisoAtrasadosInput {
  perfil_id: string
  activo: boolean
  hora: number
  dias: number[]
}

export interface GuardarConfigDigestInput {
  perfil_id: string
  activo: boolean
  hora_local: number
  dias_semana: number[]
  secciones: string[]
}

// =============================================================================
// QUERY KEYS
// =============================================================================

export const botDigestConfigKeys = {
  all: ['bot_digest_config'] as const,
  lista: () => [...botDigestConfigKeys.all, 'lista'] as const,
}

// =============================================================================
// FETCHERS
// =============================================================================

async function fetchConfigDigest(): Promise<BotDigestConfig[]> {
  const { data, error } = await supabase.rpc('bot_admin_listar_config_digest')
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar la configuración del digest. Revisá la señal e intentá de nuevo.')
  return (data as BotDigestConfig[] | null) ?? []
}

async function guardarConfigDigest(input: GuardarConfigDigestInput): Promise<void> {
  const { error } = await supabase.rpc('bot_admin_guardar_config_digest', {
    p_perfil_id: input.perfil_id,
    p_activo: input.activo,
    p_hora_local: input.hora_local,
    p_dias: input.dias_semana,
    p_secciones: input.secciones,
  })
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la configuración del digest. Revisá la configuración del digest antes de reintentar, puede haber quedado hecho.')
}

async function guardarAvisoAtrasados(input: GuardarAvisoAtrasadosInput): Promise<void> {
  const { error } = await supabase.rpc('bot_admin_guardar_aviso_atrasados', {
    p_perfil_id: input.perfil_id,
    p_activo: input.activo,
    p_hora: input.hora,
    p_dias: input.dias,
  })
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el aviso de clientes atrasados. Revisá la configuración antes de reintentar, puede haber quedado hecho.')
}

// =============================================================================
// HOOKS
// =============================================================================

/** Configuración del digest de cada admin vinculado al bot. */
export function useBotDigestConfigQuery(): UseQueryResult<BotDigestConfig[], Error> {
  return useQuery<BotDigestConfig[], Error>({
    queryKey: botDigestConfigKeys.lista(),
    queryFn: fetchConfigDigest,
    staleTime: 60 * 1000,
  })
}

/** Guarda la configuración de una persona e invalida el listado. */
export function useGuardarBotDigestConfigMutation(): UseMutationResult<
  void,
  Error,
  GuardarConfigDigestInput
> {
  const queryClient = useQueryClient()
  return useMutation<void, Error, GuardarConfigDigestInput>({
    mutationFn: guardarConfigDigest,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: botDigestConfigKeys.lista() })
    },
  })
}

/** Guarda el aviso semanal de clientes atrasados de un preventista e invalida el listado. */
export function useGuardarAvisoAtrasadosMutation(): UseMutationResult<
  void,
  Error,
  GuardarAvisoAtrasadosInput
> {
  const queryClient = useQueryClient()
  return useMutation<void, Error, GuardarAvisoAtrasadosInput>({
    mutationFn: guardarAvisoAtrasados,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: botDigestConfigKeys.lista() })
    },
  })
}

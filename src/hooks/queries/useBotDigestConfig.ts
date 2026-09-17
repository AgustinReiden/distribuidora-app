/**
 * TanStack Query hooks para la configuración del digest de Telegram.
 *
 * Wrappers de dos RPCs SECURITY DEFINER gateadas por `perfiles.rol = 'admin'`:
 *   * bot_admin_listar_config_digest()
 *   * bot_admin_guardar_config_digest(p_perfil_id, p_activo, p_hora_local,
 *                                     p_dias, p_secciones)
 *
 * Mismo patrón que `useBotAdmin`: la ruta ya está gateada a admin, así que
 * estos hooks no se montan para nadie más.
 */
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
  type SeccionDigestKey,
} from '../../utils/digestSecciones'

// =============================================================================
// TYPES
// =============================================================================

export interface BotDigestConfig {
  perfil_id: string
  perfil_nombre: string | null
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
  if (error) throw error
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
  if (error) throw error
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

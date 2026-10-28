/**
 * Rubros de gasto. Son globales (de toda la red): la key no lleva sucursal.
 * Se escriben por `guardar_rubro_gasto`, sólo admin.
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import type { GrupoGasto, RubroGasto } from '../../types/gastos'

export const rubrosGastoKeys = {
  all: () => ['rubros-gasto'] as const,
}

const RUBRO_COLUMNAS = 'id,nombre,grupo,palabras_busqueda,pide_litros_km,reparto_sugerido_meses,sugiere_mes_anterior,activo'

export interface GuardarRubroGastoInput {
  id?: number
  nombre: string
  grupo: GrupoGasto
  palabras_busqueda?: string | null
  activo?: boolean
  pide_litros_km?: boolean
  reparto_sugerido_meses?: number | null
  sugiere_mes_anterior?: boolean
}

/** Todos los rubros, activos o no: la pantalla de rubros necesita reactivarlos. */
export function useRubrosGastoQuery() {
  return useQuery({
    queryKey: rubrosGastoKeys.all(),
    queryFn: async (): Promise<RubroGasto[]> => {
      const { data, error } = await supabase
        .from('gasto_rubros')
        .select(RUBRO_COLUMNAS)
        .order('grupo')
        .order('nombre')
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudieron cargar los rubros. Revisá la señal e intentá de nuevo.')
      return (data ?? []) as RubroGasto[]
    },
    staleTime: 5 * 60 * 1000,
  })
}

/** Guarda y devuelve el rubro recién guardado, leído de nuevo. */
export function useGuardarRubroGastoMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (rubro: GuardarRubroGastoInput): Promise<RubroGasto> => {
      const { data: id, error } = await supabase.rpc('guardar_rubro_gasto', { p_rubro: rubro })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el rubro. Revisá la lista antes de reintentar, puede haber quedado guardado.')
      const { data, error: errorLectura } = await supabase
        .from('gasto_rubros')
        .select(RUBRO_COLUMNAS)
        .eq('id', id as number)
        .single()
      if (errorLectura) throw errorDeSupabase(errorLectura, 'El rubro se guardó, pero no se pudo volver a leer. Recargá la lista.')
      return data as RubroGasto
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: rubrosGastoKeys.all() })
    },
  })
}

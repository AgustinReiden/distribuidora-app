/**
 * Sucursales activas de la red. Sirve para el aviso del gasto compartido y para
 * saber si el usuario tiene TODAS (de eso depende quién edita un compartido).
 * `authenticated` las lee por la policy `read_sucursales`.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'

export interface SucursalActiva {
  id: number
  nombre: string
}

export const sucursalesActivasKeys = {
  all: () => ['sucursales-activas'] as const,
}

export function useSucursalesActivasQuery() {
  return useQuery({
    queryKey: sucursalesActivasKeys.all(),
    queryFn: async (): Promise<SucursalActiva[]> => {
      const { data, error } = await supabase
        .from('sucursales')
        .select('id,nombre')
        .eq('activa', true)
        .order('id')
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudieron cargar las sucursales. Revisá la señal e intentá de nuevo.')
      return (data ?? []) as SucursalActiva[]
    },
    staleTime: 30 * 60 * 1000,
  })
}

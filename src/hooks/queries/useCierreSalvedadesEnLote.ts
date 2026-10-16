/**
 * Cierre en lote del atraso de salvedades (#1198).
 *
 * RPC `cerrar_salvedades_en_lote(p_hasta, p_notas, p_solo_contar)`. Sólo admin
 * (el espejo en la UI es `puedeAnularSalvedad`, que es el mismo "sólo admin"),
 * sobre la sucursal activa. Cierra como `resuelto_otro` las pendientes cargadas
 * hasta `p_hasta` (día argentino), con una nota que dice que fue un cierre en
 * lote y hasta qué fecha.
 *
 * Cerrar NO mueve stock ni plata y NO pasa por `anular_salvedad`: el stock se
 * movió al registrar la salvedad. Por eso tampoco cambia el reporte de
 * rechazos: una salvedad resuelta sigue siendo un rechazo.
 *
 * `p_solo_contar = true` devuelve cuántas cerraría sin tocar nada: es lo que
 * muestra el modal antes de pedir la confirmación.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useSucursal } from '../../contexts/SucursalContext'
import { salvedadesKeys } from './useSalvedadesQuery'
import { rechazosReporteKeys } from './useRechazosReporteQuery'

interface RespuestaCierre {
  success?: boolean
  error?: string
  cerradas?: number
  nota?: string
}

export interface ResultadoCierreEnLote {
  cerradas: number
  nota: string | null
}

async function llamarCierre(hasta: string, notas: string | null, soloContar: boolean): Promise<ResultadoCierreEnLote> {
  const { data, error } = await supabase.rpc('cerrar_salvedades_en_lote', {
    p_hasta: hasta,
    p_notas: notas,
    p_solo_contar: soloContar,
  })
  if (error) {
    throw errorDeSupabase(
      error,
      soloContar
        ? 'Sin conexión: no se pudo contar las salvedades a cerrar.'
        : 'Sin conexión: no se pudo confirmar el cierre en lote. Revisá si quedó hecho antes de reintentar.',
    )
  }
  const r = (data ?? {}) as RespuestaCierre
  if (!r.success) throw new Error(r.error || 'No se pudo cerrar las salvedades en lote')
  return { cerradas: Number(r.cerradas ?? 0), nota: r.nota ?? null }
}

/** Cuántas pendientes de la sucursal activa se cerrarían hasta `hasta`. */
export function contarSalvedadesEnLote(hasta: string): Promise<number> {
  return llamarCierre(hasta, null, true).then((r) => r.cerradas)
}

export function cerrarSalvedadesEnLote(input: { hasta: string; notas?: string }): Promise<ResultadoCierreEnLote> {
  return llamarCierre(input.hasta, input.notas?.trim() || null, false)
}

export function useConteoCierreEnLoteQuery(hasta: string, enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: [...salvedadesKeys.sucursal(currentSucursalId), 'cierre-en-lote', hasta] as const,
    queryFn: () => contarSalvedadesEnLote(hasta),
    enabled: enabled && Boolean(hasta),
  })
}

/** Al cerrar, refresca la lista, los KPIs y el conteo (todo cuelga de `salvedadesKeys.all`). */
export function useCerrarSalvedadesEnLoteMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: cerrarSalvedadesEnLote,
    onSuccess: async () => {
      // El reporte de rechazos muestra cuántas siguen pendientes.
      void queryClient.invalidateQueries({ queryKey: rechazosReporteKeys.all })
      await queryClient.invalidateQueries({ queryKey: salvedadesKeys.all })
    },
  })
}

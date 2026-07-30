/**
 * Revisión de horarios en texto libre (migs 140-141, RPC de la 152).
 *
 * El backfill convirtió lo interpretable con confianza; lo demás quedó en texto
 * libre. Esos clientes caen en la barrida 2 —"sin horario cargado"—, que es la
 * bolsa de los que no sabemos cuándo abren, así que el ruteo por horarios no
 * los puede acomodar.
 *
 * El parseo corre en el navegador con `parseHorarioLibre`, que es el mismo
 * código con tests contra estos casos reales. La DB sólo recibe decisiones ya
 * tomadas y valida el formato.
 */
import { useMemo } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { clientesKeys } from './useClientesQuery'
import { parseHorarioLibre, type HorarioParseado } from '../../utils/parseHorarioLibre'
import { serializarFranjas } from '../../utils/horariosCliente'

/** Formato canónico "HH:MM-HH:MM[ y HH:MM-HH:MM]". Espejo del CHECK del RPC. */
const RE_CANONICO = /^\d{2}:\d{2}-\d{2}:\d{2}( y \d{2}:\d{2}-\d{2}:\d{2})*$/

export interface ClienteHorarioPendiente {
  id: string
  nombre: string
  /** El texto tal como lo cargó el preventista. */
  original: string
  /** Lo que el parser propone; franjas vacías = no entendió nada. */
  propuesta: HorarioParseado
  /** La propuesta serializada al formato canónico, o '' si no hay. */
  propuestaTexto: string
}

export const revisionHorariosKeys = {
  all: (sucursalId: number | null) => ['revision-horarios', sucursalId] as const,
}

interface FilaCliente {
  id: string
  nombre_fantasia: string | null
  razon_social: string | null
  horarios_atencion: string | null
}

async function fetchClientesConTextoLibre(): Promise<FilaCliente[]> {
  const { data, error } = await supabase
    .from('clientes')
    .select('id, nombre_fantasia, razon_social, horarios_atencion')
    .not('horarios_atencion', 'is', null)
    .neq('horarios_atencion', '')
    .order('nombre_fantasia')

  if (error) throw error
  return (data as FilaCliente[]) || []
}

/**
 * Clientes cuyo horario NO está en formato canónico, con la propuesta del
 * parser. El filtro de "canónico" se hace acá y no en la query porque
 * PostgREST no expone regex de Postgres de forma portable.
 */
export function useRevisionHorariosQuery(enabled = true) {
  const { currentSucursalId } = useSucursal()
  const query = useQuery({
    queryKey: revisionHorariosKeys.all(currentSucursalId),
    queryFn: fetchClientesConTextoLibre,
    enabled,
    staleTime: 5 * 60 * 1000,
  })

  const pendientes = useMemo((): ClienteHorarioPendiente[] => {
    const filas = query.data ?? []
    const out: ClienteHorarioPendiente[] = []
    for (const c of filas) {
      const original = (c.horarios_atencion || '').trim()
      if (!original || RE_CANONICO.test(original)) continue
      const propuesta = parseHorarioLibre(original)
      out.push({
        id: String(c.id),
        nombre: c.nombre_fantasia || c.razon_social || `Cliente ${c.id}`,
        original,
        propuesta,
        propuestaTexto: propuesta.franjas.length > 0 ? serializarFranjas(propuesta.franjas) : '',
      })
    }
    return out
  }, [query.data])

  return { ...query, pendientes }
}

export interface HorarioMasivoItem {
  cliente_id: string
  horarios_atencion: string
  dias_atencion?: string | null
}

export function useGuardarHorariosMasivoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async (items: HorarioMasivoItem[]): Promise<number> => {
      const { data, error } = await supabase.rpc('guardar_horario_cliente_masivo', {
        p_items: items,
      })
      if (error) throw error
      const r = data as { success: boolean; actualizados: number } | null
      if (!r || r.success === false) throw new Error('No se pudieron guardar los horarios')
      return r.actualizados
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: revisionHorariosKeys.all(currentSucursalId) })
      // El horario alimenta el ruteo y la ficha del cliente.
      queryClient.invalidateQueries({ queryKey: clientesKeys.all(currentSucursalId) })
    },
  })
}

/**
 * Los emails de otros usuarios (#1601, 1601-b5; decisión del dueño D53: los leen admin y
 * encargado). Salen de la RPC `emails_de_usuarios(p_ids)`, que a cualquier otro rol le da
 * sólo el suyo, y no de la tabla: la lectura por REST de `perfiles.email` se cierra.
 *
 * Mientras la migración que crea la RPC no esté aplicada (PGRST202: la función no existe),
 * se leen de la tabla como siempre (`select('id, email')`), que hasta ese cierre sigue
 * concedida. Esa lectura de respaldo es la única del front que nombra `email`.
 *
 * Un error (sin señal, un 5xx) se tira: la pantalla de usuarios lo muestra con su
 * «Reintentar» y la lista sale igual, sin emails. El email no traba nada: no se edita.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useSucursal } from '../../contexts/SucursalContext'

type FilaEmail = { id: string; email: string | null }

function aMapa(filas: FilaEmail[] | null | undefined): Map<string, string> {
  const mapa = new Map<string, string>()
  for (const f of filas ?? []) {
    if (f?.id && f.email) mapa.set(f.id, f.email)
  }
  return mapa
}

/** El código de PostgREST para «la función no existe» (todavía no se aplicó la migración). */
const FUNCION_INEXISTENTE = 'PGRST202'
const SIN_CONEXION = 'Sin conexión: no se pudieron cargar los emails de los usuarios. Revisá la señal e intentá de nuevo.'

export async function fetchEmailsDeUsuarios(ids: string[]): Promise<Map<string, string>> {
  const unicos = [...new Set(ids.filter(Boolean))].sort()
  if (unicos.length === 0) return new Map()
  const { data, error } = await supabase.rpc('emails_de_usuarios', { p_ids: unicos })
  if (!error) return aMapa(data as FilaEmail[] | null)
  if (error.code !== FUNCION_INEXISTENTE) throw errorDeSupabase(error, SIN_CONEXION)
  const respaldo = await supabase.from('perfiles').select('id, email').in('id', unicos)
  if (respaldo.error) throw errorDeSupabase(respaldo.error, SIN_CONEXION)
  return aMapa(respaldo.data as FilaEmail[] | null)
}

/** Los emails de esos usuarios, para la pantalla de usuarios (admin). */
export function useEmailsDeUsuariosQuery(ids: string[]) {
  const { currentSucursalId } = useSucursal()
  const unicos = [...new Set(ids.filter(Boolean))].sort()
  return useQuery({
    queryKey: ['usuarios', currentSucursalId, 'emails', unicos] as const,
    queryFn: () => fetchEmailsDeUsuarios(unicos),
    enabled: unicos.length > 0,
    staleTime: 10 * 60 * 1000,
  })
}

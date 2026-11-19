/**
 * Los emails de otros usuarios (#1601, 1601-b5; decisión del dueño D53: los leen admin y
 * encargado). Salen de la RPC `emails_de_usuarios(p_ids)`, que a cualquier otro rol le da
 * sólo el suyo. `perfiles.email` no se lee por REST: los cierres de la tarjeta C6 se lo sacaron
 * a `authenticated` (por eso ya no hay lectura de respaldo de la tabla).
 *
 * Un error (sin señal, un 5xx, la RPC que no existe) se tira: la pantalla de usuarios lo muestra
 * con su «Reintentar» y la lista sale igual, sin emails. El email no traba nada: no se edita.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useSucursal } from '../../contexts/SucursalContext'

type FilaEmail = { id: string; email: string | null }

const SIN_CONEXION = 'Sin conexión: no se pudieron cargar los emails de los usuarios. Revisá la señal e intentá de nuevo.'

export async function fetchEmailsDeUsuarios(ids: string[]): Promise<Map<string, string>> {
  const unicos = [...new Set(ids.filter(Boolean))].sort()
  const mapa = new Map<string, string>()
  if (unicos.length === 0) return mapa
  const { data, error } = await supabase.rpc('emails_de_usuarios', { p_ids: unicos })
  if (error) throw errorDeSupabase(error, SIN_CONEXION)
  for (const f of (data as FilaEmail[] | null) ?? []) {
    if (f?.id && f.email) mapa.set(f.id, f.email)
  }
  return mapa
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

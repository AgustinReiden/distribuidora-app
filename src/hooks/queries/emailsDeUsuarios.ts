/**
 * Los emails de otros usuarios (#1601, 1601-b5; decisión del dueño D53: los leen admin y
 * encargado). Salen de la RPC `emails_de_usuarios(p_ids)`, que a cualquier otro rol le da
 * sólo el suyo, y no de la tabla: la lectura por REST de `perfiles.email` se cierra.
 *
 * Mientras la migración que crea la RPC no esté aplicada (PGRST202: la función no existe),
 * se leen de la tabla como siempre (`select('id, email')`), que hasta ese cierre sigue
 * concedida. Esa lectura de respaldo es la única del front nuevo que nombra `email`.
 *
 * Nunca rompe a quien la llama: sin red, o con otro error, devuelve un mapa vacío y la
 * pantalla muestra a los usuarios sin el email.
 */
import { supabase } from '../supabase/base'

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

export async function fetchEmailsDeUsuarios(ids: string[]): Promise<Map<string, string>> {
  const unicos = [...new Set(ids.filter(Boolean))]
  if (unicos.length === 0) return new Map()
  try {
    const { data, error } = await supabase.rpc('emails_de_usuarios', { p_ids: unicos })
    if (!error) return aMapa(data as FilaEmail[] | null)
    if (error.code !== FUNCION_INEXISTENTE) return new Map()
    const respaldo = await supabase.from('perfiles').select('id, email').in('id', unicos)
    return respaldo.error ? new Map() : aMapa(respaldo.data as FilaEmail[] | null)
  } catch {
    return new Map()
  }
}

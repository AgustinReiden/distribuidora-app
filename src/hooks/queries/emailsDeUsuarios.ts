/**
 * Los emails de otros usuarios (#1601, 1601-b5; decisión del dueño D53: los leen admin y
 * encargado). Salen de la RPC `emails_de_usuarios(p_ids)`, que a cualquier otro rol le da
 * sólo el suyo. `perfiles.email` no se lee por REST: la migración de cierres de la tarjeta C6
 * se lo sacó a `authenticated` (por eso ya no hay lectura de respaldo de la tabla).
 *
 * Nunca rompe a quien la llama: sin red, o con un error, devuelve un mapa vacío y la
 * pantalla muestra a los usuarios sin el email.
 */
import { supabase } from '../supabase/base'

type FilaEmail = { id: string; email: string | null }

export async function fetchEmailsDeUsuarios(ids: string[]): Promise<Map<string, string>> {
  const unicos = [...new Set(ids.filter(Boolean))]
  const mapa = new Map<string, string>()
  if (unicos.length === 0) return mapa
  try {
    const { data, error } = await supabase.rpc('emails_de_usuarios', { p_ids: unicos })
    if (error) return mapa
    for (const f of (data as FilaEmail[] | null) ?? []) {
      if (f?.id && f.email) mapa.set(f.id, f.email)
    }
  } catch {
    // Sin red: la lista sale sin emails.
  }
  return mapa
}

/**
 * Lee de la base (no del caché) los precios de unos productos, para el aumento
 * masivo (FRG2-3, #1599). Ver `utils/preciosVigentes.ts`.
 */
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import type { PrecioVigente } from '../../utils/preciosVigentes'

/** Ids por consulta: un `in` con miles de ids pasa el largo de la URL. */
const IDS_POR_CONSULTA = 200

export async function leerPreciosVigentes(ids: readonly string[]): Promise<PrecioVigente[]> {
  const filas: PrecioVigente[] = []
  for (let i = 0; i < ids.length; i += IDS_POR_CONSULTA) {
    const tanda = ids.slice(i, i + IDS_POR_CONSULTA)
    const { data, error } = await supabase
      .from('productos')
      .select('id, precio, precio_sin_iva, condicion_iva, porcentaje_iva')
      .in('id', tanda)
      .order('id')
    if (error) {
      throw errorDeSupabase(error, 'Sin conexión: no se pudieron verificar los precios actuales. No se aplicó nada: revisá la señal e intentá de nuevo.')
    }
    for (const f of (data ?? []) as unknown as Array<Record<string, unknown>>) {
      filas.push({
        id: String(f.id),
        precio: f.precio == null ? null : Number(f.precio),
        precio_sin_iva: f.precio_sin_iva == null ? null : Number(f.precio_sin_iva),
        condicion_iva: (f.condicion_iva as string | null | undefined) ?? null,
        porcentaje_iva: f.porcentaje_iva == null ? null : Number(f.porcentaje_iva),
      })
    }
  }
  return filas
}

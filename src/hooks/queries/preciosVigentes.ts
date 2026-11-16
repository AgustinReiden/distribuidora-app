/**
 * Lee de la base (no del caché) los precios de unos productos, para el aumento
 * masivo (FRG2-3, #1599). Ver `utils/preciosVigentes.ts`.
 */
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import type { PrecioVigente } from '../../utils/preciosVigentes'

/** Ids por consulta: un `in` con miles de ids pasa el largo de la URL. */
const IDS_POR_CONSULTA = 200

/** Lo que devuelve PostgREST: numeric puede llegar como string. */
interface FilaPrecio {
  id: string | number
  precio: string | number | null
  precio_sin_iva: string | number | null
  condicion_iva: string | null
  porcentaje_iva: string | number | null
}

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
    const filasTanda: FilaPrecio[] = data ?? []
    for (const f of filasTanda) {
      filas.push({
        id: String(f.id),
        precio: f.precio == null ? null : Number(f.precio),
        precio_sin_iva: f.precio_sin_iva == null ? null : Number(f.precio_sin_iva),
        condicion_iva: f.condicion_iva ?? null,
        porcentaje_iva: f.porcentaje_iva == null ? null : Number(f.porcentaje_iva),
      })
    }
  }
  return filas
}

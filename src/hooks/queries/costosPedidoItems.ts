/**
 * Costo de la venta de cada ítem por la RPC `costos_pedido_items()` (#1003).
 *
 * Desde #1003 `pedido_items.costo_unitario_al_crear` no se lee por REST. La RPC
 * lo devuelve sólo a admin y encargado (de la sucursal actual); a cualquier
 * otro rol le devuelve cero filas, sin error. Por eso se la llama sin preguntar
 * el rol: el preventista y el transportista reciben los ítems tal cual, sin
 * costo.
 *
 * Si la RPC FALLA, se propaga el error en vez de seguir sin costos: un export o
 * un backup con el costo en blanco parece completo y no lo es (mismo criterio
 * que `costosProductos.ts`, #974).
 */
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'

/**
 * Ids por llamada. La respuesta de la RPC la corta el tope de filas de
 * PostgREST (1.000): de a 500 ninguna tanda llega al tope.
 */
const TANDA = 500

/** Mapa id del ítem (como string) → costo unitario al crear la venta. */
export async function fetchCostosPedidoItems(
  ids: ReadonlyArray<string | number>,
): Promise<Map<string, number | null>> {
  const unicos = [...new Set(ids.map(Number))]
  const mapa = new Map<string, number | null>()
  for (let i = 0; i < unicos.length; i += TANDA) {
    const { data, error } = await supabase.rpc('costos_pedido_items', { p_ids: unicos.slice(i, i + TANDA) })
    if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar el costo de los ítems de las ventas. Revisá la señal e intentá de nuevo.')
    for (const fila of (data as Array<{ id: string | number; costo_unitario_al_crear: number | null }> | null) || []) {
      mapa.set(String(fila.id), fila.costo_unitario_al_crear)
    }
  }
  return mapa
}

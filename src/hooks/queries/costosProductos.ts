/**
 * Costos de productos por la RPC `costos_productos()` (#974).
 *
 * Desde #974 las columnas de costo de `productos` no se leen por REST. La RPC
 * las devuelve sólo a admin y encargado (de la sucursal actual); a cualquier
 * otro rol le devuelve cero filas, sin error. Por eso se la llama sin preguntar
 * el rol: el preventista recibe los productos tal cual, sin costos.
 *
 * Si la RPC FALLA, se propaga el error en vez de seguir sin costos. No es
 * cosmético: la ficha del producto arranca el form con los costos que trae el
 * producto, y guardarla con esos campos vacíos escribe NULL encima de los
 * costos reales. Mejor un catálogo que no carga que uno que borra costos.
 */
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { COLUMNAS_COSTO_PRODUCTO } from '../../lib/productoColumnas'

type ColumnaCosto = typeof COLUMNAS_COSTO_PRODUCTO[number]
export type CostosProducto = Record<ColumnaCosto, number | null>

/**
 * Ids por llamada. La respuesta de la RPC la corta el tope de filas de
 * PostgREST (1.000): de a 500 ninguna tanda llega al tope.
 */
const TANDA = 500

/** Mapa id (como string) → costos de esos productos. */
export async function fetchCostosProductos(
  ids: ReadonlyArray<string | number>,
): Promise<Map<string, CostosProducto>> {
  const unicos = [...new Set(ids.map(Number))]
  const mapa = new Map<string, CostosProducto>()
  for (let i = 0; i < unicos.length; i += TANDA) {
    const { data, error } = await supabase.rpc('costos_productos', { p_ids: unicos.slice(i, i + TANDA) })
    if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar los costos de los productos. Revisá la señal e intentá de nuevo.')
    for (const fila of (data as Array<{ id: string | number } & CostosProducto> | null) || []) {
      mapa.set(String(fila.id), {
        costo_real: fila.costo_real,
        costo_promedio: fila.costo_promedio,
        costo_sin_iva: fila.costo_sin_iva,
        costo_con_iva: fila.costo_con_iva,
      })
    }
  }
  return mapa
}

/**
 * Devuelve los productos con sus costos pegados por id. Un producto sin fila en
 * la RPC (rol sin acceso) queda como vino, sin las claves de costo.
 *
 * Pide a la RPC exactamente esos ids, no "todos los de la sucursal": la
 * respuesta de una RPC también la corta el tope de filas de PostgREST (1.000),
 * y sin orden ni ids el recorte no coincidiría con la lista, así que algún
 * producto quedaría sin costo y la ficha lo guardaría en NULL.
 */
export async function conCostos<T extends { id: string | number }>(
  productos: T[],
): Promise<T[]> {
  if (productos.length === 0) return productos
  const costos = await fetchCostosProductos(productos.map(p => p.id))
  if (costos.size === 0) return productos
  return productos.map(p => {
    const c = costos.get(String(p.id))
    return c ? { ...p, ...c } : p
  })
}

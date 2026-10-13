/**
 * Datos de la lista de precios en PDF, leídos en el momento de generarla.
 *
 * No sale de la caché de TanStack a propósito: productos y condiciones tienen
 * 10 min de staleTime, y la lista dice "precios vigentes al día de hoy". Un
 * precio cambiado hace 5 minutos tiene que salir en el PDF.
 *
 * De productos se piden SÓLO las columnas que la lista usa (un subconjunto de
 * `PRODUCTO_COLUMNAS`, sin `*`): stock, código, proveedor y demás no llegan ni
 * al navegador por este camino. Las condiciones son las mismas que lee la carga
 * del pedido (`fetchGruposPrecio`). Todo va por RLS a la sucursal activa.
 */
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { fetchGruposPrecio } from './useGruposPrecioQuery'
import type { EntradaListaPrecios, ProductoListaPrecios } from '../../utils/listaPrecios'

const COLUMNAS_LISTA_PRECIOS = 'id, nombre, precio, activo, categoria, subcategoria_id'

const SIN_CONEXION = 'Sin conexión: no se pudo armar la lista de precios. Revisá la señal e intentá de nuevo.'

export async function fetchDatosListaPrecios(): Promise<EntradaListaPrecios> {
  const [productos, subrubros, grupos] = await Promise.all([
    supabase.from('productos').select(COLUMNAS_LISTA_PRECIOS).order('nombre'),
    supabase.from('categorias').select('id, nombre, activa').not('parent_id', 'is', null),
    fetchGruposPrecio(),
  ])

  if (productos.error) throw errorDeSupabase(productos.error, SIN_CONEXION)
  if (subrubros.error) throw errorDeSupabase(subrubros.error, SIN_CONEXION)

  return {
    productos: (productos.data ?? []) as unknown as ProductoListaPrecios[],
    grupos,
    // Un subrubro dado de baja no titula nada: su producto queda bajo el rubro.
    nombresSubrubro: new Map(
      (subrubros.data ?? [])
        .filter(s => s.activa !== false)
        .map(s => [String(s.id), String(s.nombre)]),
    ),
  }
}

/**
 * TanStack Query hook para "Stock de la red" (RPC `reporte_stock_red`).
 *
 * SOLO LECTURA y CROSS-SUCURSAL: devuelve stock, costo y precio de TODAS las
 * sucursales activas, sin importar a cuáles esté asignado el admin. Es un RPC
 * y no una consulta a `productos` a propósito: la policy `mt_productos_select`
 * aísla por sucursal y abrirla filtraría de más (el selector de items del
 * pedido, las mermas, el backup a Excel) y expondría la fila entera. El RPC
 * elige columna por columna.
 *
 * CACHE: key propia. NO puede colgar de `productosKeys.all(sucursalId)` — el
 * dato no es de la sucursal activa y `switchSucursal` invalida todo eso.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import type { ProductoRed } from '../../utils/stockRed'

export interface StockRedSucursal {
  sucursal_id: number
  sucursal_nombre: string
  productos: number
  productos_con_stock: number
  unidades: number
  valuacion_promedio: number
}

export interface StockRed {
  meta: {
    sucursal_id: number | null
    sucursal_nombre: string
    generado_at: string
    criterio: string
  }
  sucursales: StockRedSucursal[]
  productos: ProductoRed[]
}

export const stockRedKeys = {
  all: ['stock-red'] as const,
  scope: (sucursalId: number | null) => ['stock-red', sucursalId] as const,
}

export function useStockRedQuery(sucursalId: number | null = null, enabled = true) {
  return useQuery({
    queryKey: stockRedKeys.scope(sucursalId),
    queryFn: async (): Promise<StockRed> => {
      const { data, error } = await supabase.rpc('reporte_stock_red', {
        p_sucursal_id: sucursalId,
      })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar el stock de la red. Revisá la señal e intentá de nuevo.')
      return data as StockRed
    },
    enabled,
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * TanStack Query hook para el reporte de valuación de inventario (mig 131).
 *
 * RPC `reporte_valuacion_inventario(p_sucursal_id)`: stock valuado a costo
 * promedio ponderado (mig 127) con comparativa a costo de reposición.
 * p_sucursal_id NULL = consolidado de las sucursales asignadas al usuario
 * (admin/encargado); el desglose por sucursal viene en la respuesta.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'

export interface ValuacionProducto {
  producto_id: number
  nombre: string
  categoria: string
  sucursal_id: number
  sucursal_nombre: string
  stock: number
  costo_promedio: number | null
  costo_reposicion: number | null
  ultimo_tipo_compra: 'FC' | 'ZZ' | null
  valuacion_promedio: number
  valuacion_reposicion: number
  diferencia: number
}

export interface ValuacionCategoria {
  categoria: string
  productos: number
  unidades: number
  valuacion_promedio: number
  valuacion_reposicion: number
  diferencia: number
}

export interface ValuacionSucursal {
  sucursal_id: number
  sucursal_nombre: string
  productos: number
  unidades: number
  valuacion_promedio: number
  valuacion_reposicion: number
}

export interface ValuacionInventario {
  meta: {
    sucursal_id: number | null
    sucursal_nombre: string
    generado_at: string
    criterio: string
  }
  totales: {
    productos: number
    unidades: number
    valuacion_promedio: number
    valuacion_reposicion: number
    diferencia: number
  }
  sucursales: ValuacionSucursal[]
  categorias: ValuacionCategoria[]
  productos: ValuacionProducto[]
  calidad_datos: {
    stock_negativo: number
    sin_costo: number
    detalle_stock_negativo: { producto_id: number; nombre: string; stock: number }[]
  }
}

export function useValuacionInventarioQuery(sucursalId: number | null = null, enabled = true) {
  return useQuery({
    queryKey: ['valuacion-inventario', sucursalId] as const,
    queryFn: async (): Promise<ValuacionInventario> => {
      const { data, error } = await supabase.rpc('reporte_valuacion_inventario', {
        p_sucursal_id: sucursalId,
      })
      if (error) throw new Error(error.message)
      return data as ValuacionInventario
    },
    enabled,
    staleTime: 5 * 60 * 1000,
  })
}

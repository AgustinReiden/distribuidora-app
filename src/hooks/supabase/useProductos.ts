/**
 * useProductos - Lectura de productos para la sincronización offline de App.tsx
 *
 * Sólo lee. Las escrituras que tenía (alta, edición, baja y validarStock) no las
 * usaba nadie y se sacaron en #1475: no comparaban el stock antes de pisarlo ni
 * mandaban sucursal_id en el alta. Las escrituras van por useProductosQuery.
 *
 * @deprecated Este hook usa useState/useEffect. Para nuevos componentes,
 * usar TanStack Query hooks de `src/hooks/queries/useProductosQuery.ts`:
 * - useProductosQuery() para obtener productos
 * - useCrearProductoMutation() para crear
 * - useActualizarProductoMutation() para actualizar
 *
 * Migración: Reemplazar `const { productos } = useProductos()`
 * con `const { data: productos } = useProductosQuery()`
 */

import { useState, useEffect } from 'react'
import { supabase, notifyError } from './base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import type { ProductoDB, UseProductosReturn } from '../../types'
import { PRODUCTO_COLUMNAS } from '../../lib/productoColumnas'

export function useProductos(): UseProductosReturn {
  const [productos, setProductos] = useState<ProductoDB[]>([])
  const [loading, setLoading] = useState<boolean>(true)

  const fetchProductos = async (): Promise<void> => {
    setLoading(true)
    try {
      const { data, error } = await supabase.from('productos').select(PRODUCTO_COLUMNAS).order('nombre')
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar los productos. Revisá la señal e intentá de nuevo.')
      // Sin costos (#974): este hook sólo alimenta la sincronización offline,
      // que usa nombre y stock.
      setProductos((data as unknown as ProductoDB[]) || [])
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Error desconocido'
      notifyError('Error al cargar productos: ' + errorMessage)
      setProductos([])
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { fetchProductos() }, [])

  return {
    productos,
    loading,
    refetch: fetchProductos
  }
}

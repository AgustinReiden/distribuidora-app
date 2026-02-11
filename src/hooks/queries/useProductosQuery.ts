/**
 * TanStack Query hooks para Productos
 * Reemplaza el hook useProductos con mejor cache y gestión de estado
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import type { ProductoDB, ProductoFormInput } from '../../types'

// Query keys
export const productosKeys = {
  all: ['productos'] as const,
  lists: () => [...productosKeys.all, 'list'] as const,
  list: (filters: Record<string, unknown>) => [...productosKeys.lists(), filters] as const,
  details: () => [...productosKeys.all, 'detail'] as const,
  detail: (id: string) => [...productosKeys.details(), id] as const,
  stockBajo: (umbral: number) => [...productosKeys.all, 'stockBajo', umbral] as const,
}

// Fetch functions
async function fetchProductos(): Promise<ProductoDB[]> {
  const { data, error } = await supabase
    .from('productos')
    .select('*')
    .order('nombre')

  if (error) throw error
  return (data as ProductoDB[]) || []
}

async function fetchProductoById(id: string): Promise<ProductoDB | null> {
  const { data, error } = await supabase
    .from('productos')
    .select('*')
    .eq('id', id)
    .single()

  if (error) throw error
  return data as ProductoDB
}

async function fetchProductosStockBajo(umbral: number): Promise<ProductoDB[]> {
  const { data, error } = await supabase
    .from('productos')
    .select('*')
    .lt('stock', umbral)
    .order('stock', { ascending: true })

  if (error) throw error
  return (data as ProductoDB[]) || []
}

// Mutation functions
async function createProducto(producto: ProductoFormInput): Promise<ProductoDB> {
  const { data, error } = await supabase
    .from('productos')
    .insert([{
      nombre: producto.nombre,
      codigo: producto.codigo || null,
      precio: producto.precio,
      stock: producto.stock,
      stock_minimo: producto.stock_minimo ?? 10,
      categoria: producto.categoria || null,
      proveedor_id: producto.proveedor_id || null,
      costo_sin_iva: producto.costo_sin_iva ? parseFloat(String(producto.costo_sin_iva)) : null,
      costo_con_iva: producto.costo_con_iva ? parseFloat(String(producto.costo_con_iva)) : null,
      impuestos_internos: producto.impuestos_internos ? parseFloat(String(producto.impuestos_internos)) : null,
      precio_sin_iva: producto.precio_sin_iva ? parseFloat(String(producto.precio_sin_iva)) : null
    }])
    .select()
    .single()

  if (error) throw error
  return data as ProductoDB
}

async function updateProducto({ id, data: producto }: { id: string; data: Partial<ProductoFormInput> }): Promise<ProductoDB> {
  const updateData: Record<string, unknown> = {}
  if (producto.nombre !== undefined) updateData.nombre = producto.nombre
  if (producto.codigo !== undefined) updateData.codigo = producto.codigo || null
  if (producto.precio !== undefined) updateData.precio = producto.precio
  if (producto.stock !== undefined) updateData.stock = producto.stock
  if (producto.stock_minimo !== undefined) updateData.stock_minimo = producto.stock_minimo
  if (producto.categoria !== undefined) updateData.categoria = producto.categoria || null
  if (producto.proveedor_id !== undefined) updateData.proveedor_id = producto.proveedor_id || null
  if (producto.costo_sin_iva !== undefined) updateData.costo_sin_iva = producto.costo_sin_iva ? parseFloat(String(producto.costo_sin_iva)) : null
  if (producto.costo_con_iva !== undefined) updateData.costo_con_iva = producto.costo_con_iva ? parseFloat(String(producto.costo_con_iva)) : null
  if (producto.impuestos_internos !== undefined) updateData.impuestos_internos = producto.impuestos_internos ? parseFloat(String(producto.impuestos_internos)) : null
  if (producto.precio_sin_iva !== undefined) updateData.precio_sin_iva = producto.precio_sin_iva ? parseFloat(String(producto.precio_sin_iva)) : null

  const { data, error } = await supabase
    .from('productos')
    .update(updateData)
    .eq('id', id)
    .select()
    .single()

  if (error) throw error
  return data as ProductoDB
}

async function deleteProducto(id: string): Promise<void> {
  const { error } = await supabase
    .from('productos')
    .delete()
    .eq('id', id)

  if (error) throw error
}

// Hooks

/**
 * Hook para obtener todos los productos
 */
export function useProductosQuery() {
  return useQuery({
    queryKey: productosKeys.lists(),
    queryFn: fetchProductos,
    staleTime: 10 * 60 * 1000, // 10 minutos - productos cambian poco
  })
}

/**
 * Hook para obtener un producto por ID
 */
export function useProductoQuery(id: string) {
  return useQuery({
    queryKey: productosKeys.detail(id),
    queryFn: () => fetchProductoById(id),
    enabled: !!id,
  })
}

/**
 * Hook para obtener productos con stock bajo
 */
export function useProductosStockBajoQuery(umbral = 10) {
  return useQuery({
    queryKey: productosKeys.stockBajo(umbral),
    queryFn: () => fetchProductosStockBajo(umbral),
    staleTime: 5 * 60 * 1000, // 5 minutos
  })
}

/**
 * Hook para crear un producto
 */
export function useCrearProductoMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: createProducto,
    onSuccess: (newProducto) => {
      // Actualizar cache de lista
      queryClient.setQueryData<ProductoDB[]>(productosKeys.lists(), (old) => {
        if (!old) return [newProducto]
        return [...old, newProducto].sort((a, b) => a.nombre.localeCompare(b.nombre))
      })
      // Invalidar queries relacionadas
      queryClient.invalidateQueries({ queryKey: productosKeys.stockBajo(10) })
    },
  })
}

/**
 * Hook para actualizar un producto (con optimistic update)
 */
export function useActualizarProductoMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: updateProducto,
    // Optimistic update
    onMutate: async ({ id, data: producto }) => {
      await queryClient.cancelQueries({ queryKey: productosKeys.lists() })

      const previousProductos = queryClient.getQueryData<ProductoDB[]>(productosKeys.lists())

      // Aplicar cambios optimistamente
      queryClient.setQueryData<ProductoDB[]>(productosKeys.lists(), (old) => {
        if (!old) return old
        return old.map(p => p.id === id ? { ...p, ...producto } as ProductoDB : p)
      })

      return { previousProductos }
    },
    onError: (_, __, context) => {
      // Rollback on error
      if (context?.previousProductos) {
        queryClient.setQueryData(productosKeys.lists(), context.previousProductos)
      }
    },
    onSuccess: (updatedProducto) => {
      // Actualizar cache de detalle con datos reales del servidor
      queryClient.setQueryData(productosKeys.detail(updatedProducto.id), updatedProducto)
    },
    onSettled: () => {
      // Revalidar para asegurar consistencia
      queryClient.invalidateQueries({ queryKey: productosKeys.lists() })
      queryClient.invalidateQueries({ queryKey: productosKeys.stockBajo(10) })
    },
  })
}

/**
 * Hook para eliminar un producto
 */
export function useEliminarProductoMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: deleteProducto,
    onSuccess: (_, deletedId) => {
      // Remover de cache de detalle
      queryClient.removeQueries({ queryKey: productosKeys.detail(deletedId) })
      // Actualizar cache de lista
      queryClient.setQueryData<ProductoDB[]>(productosKeys.lists(), (old) => {
        if (!old) return []
        return old.filter(p => p.id !== deletedId)
      })
    },
  })
}

/**
 * Hook para descontar stock atómicamente
 */
export function useDescontarStockMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (items: { producto_id: string; cantidad: number }[]) => {
      const { data, error } = await supabase.rpc('descontar_stock_atomico', {
        p_items: items
      })

      if (error) throw error

      const result = data as { success: boolean; errores?: string[] } | null
      if (result && !result.success) {
        throw new Error(result.errores?.join(', ') || 'Error al descontar stock')
      }

      return items
    },
    onSuccess: (items) => {
      // Actualizar cache de lista optimistamente
      queryClient.setQueryData<ProductoDB[]>(productosKeys.lists(), (old) => {
        if (!old) return old
        return old.map(p => {
          const item = items.find(i => i.producto_id === p.id)
          if (item) return { ...p, stock: p.stock - item.cantidad }
          return p
        })
      })
      // Invalidar stock bajo
      queryClient.invalidateQueries({ queryKey: productosKeys.stockBajo(10) })
    },
  })
}

/**
 * Hook para restaurar stock atómicamente
 */
export function useRestaurarStockMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (items: { producto_id: string; cantidad: number }[]) => {
      const { error } = await supabase.rpc('restaurar_stock_atomico', {
        p_items: items
      })

      if (error) throw error
      return items
    },
    onSuccess: (items) => {
      // Actualizar cache de lista optimistamente
      queryClient.setQueryData<ProductoDB[]>(productosKeys.lists(), (old) => {
        if (!old) return old
        return old.map(p => {
          const item = items.find(i => i.producto_id === p.id)
          if (item) return { ...p, stock: p.stock + item.cantidad }
          return p
        })
      })
      // Invalidar stock bajo
      queryClient.invalidateQueries({ queryKey: productosKeys.stockBajo(10) })
    },
  })
}

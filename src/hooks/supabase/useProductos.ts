/**
 * useProductos - Hook para gestión de productos
 *
 * @deprecated Este hook usa useState/useEffect. Para nuevos componentes,
 * usar TanStack Query hooks de `src/hooks/queries/useProductosQuery.ts`:
 * - useProductosQuery() para obtener productos
 * - useCrearProductoMutation() para crear
 * - useActualizarProductoMutation() para actualizar
 * - useDescontarStockMutation() para descontar stock
 *
 * Migración: Reemplazar `const { productos } = useProductos()`
 * con `const { data: productos } = useProductosQuery()`
 */

import { useState, useEffect } from 'react'
import { supabase, notifyError } from './base'
import { logger } from '../../utils/logger'
import type { ProductoDB, ProductoFormInput, UseProductosReturn } from '../../types'

interface StockItem {
  productoId?: string;
  producto_id?: string;
  cantidad: number;
}

interface StockValidationItem {
  productoId: string;
  cantidad: number;
}

interface StockError {
  productoId: string;
  mensaje: string;
}

interface PrecioMasivoItem {
  productoId: string;
  precioNeto?: number;
  impInternos?: number;
  precioFinal?: number;
}

interface ActualizarPreciosResult {
  success: boolean;
  actualizados: number;
  errores: string[];
}

interface DescontarStockRPCResult {
  success: boolean;
  errores?: string[];
}

export function useProductos(): UseProductosReturn {
  const [productos, setProductos] = useState<ProductoDB[]>([])
  const [loading, setLoading] = useState<boolean>(true)

  const fetchProductos = async (): Promise<void> => {
    setLoading(true)
    try {
      const { data, error } = await supabase.from('productos').select('*').order('nombre')
      if (error) throw error
      setProductos((data as ProductoDB[]) || [])
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Error desconocido'
      notifyError('Error al cargar productos: ' + errorMessage)
      setProductos([])
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { fetchProductos() }, [])

  const agregarProducto = async (producto: ProductoFormInput): Promise<ProductoDB> => {
    const { data, error } = await supabase.from('productos').insert([{
      nombre: producto.nombre,
      codigo: producto.codigo || null,
      precio: producto.precio,
      stock: producto.stock,
      stock_minimo: producto.stock_minimo !== undefined ? producto.stock_minimo : 10,
      categoria: producto.categoria || null,
      costo_sin_iva: producto.costo_sin_iva ? parseFloat(String(producto.costo_sin_iva)) : null,
      costo_con_iva: producto.costo_con_iva ? parseFloat(String(producto.costo_con_iva)) : null,
      impuestos_internos: producto.impuestos_internos ? parseFloat(String(producto.impuestos_internos)) : null,
      precio_sin_iva: producto.precio_sin_iva ? parseFloat(String(producto.precio_sin_iva)) : null
    }]).select().single()
    if (error) throw error
    const newProducto = data as ProductoDB
    setProductos(prev => [...prev, newProducto].sort((a, b) => a.nombre.localeCompare(b.nombre)))
    return newProducto
  }

  const actualizarProducto = async (id: string, producto: Partial<ProductoFormInput>): Promise<ProductoDB> => {
    const updateData: Record<string, unknown> = {}
    if (producto.nombre !== undefined) updateData.nombre = producto.nombre
    if (producto.codigo !== undefined) updateData.codigo = producto.codigo || null
    if (producto.precio !== undefined) updateData.precio = producto.precio
    if (producto.stock !== undefined) updateData.stock = producto.stock
    if (producto.stock_minimo !== undefined) updateData.stock_minimo = producto.stock_minimo
    if (producto.categoria !== undefined) updateData.categoria = producto.categoria || null
    if (producto.costo_sin_iva !== undefined) updateData.costo_sin_iva = producto.costo_sin_iva ? parseFloat(String(producto.costo_sin_iva)) : null
    if (producto.costo_con_iva !== undefined) updateData.costo_con_iva = producto.costo_con_iva ? parseFloat(String(producto.costo_con_iva)) : null
    if (producto.impuestos_internos !== undefined) updateData.impuestos_internos = producto.impuestos_internos ? parseFloat(String(producto.impuestos_internos)) : null
    if (producto.precio_sin_iva !== undefined) updateData.precio_sin_iva = producto.precio_sin_iva ? parseFloat(String(producto.precio_sin_iva)) : null

    const { data, error } = await supabase.from('productos').update(updateData).eq('id', id).select().single()
    if (error) throw error
    const updatedProducto = data as ProductoDB
    setProductos(prev => prev.map(p => p.id === id ? updatedProducto : p))
    return updatedProducto
  }

  const eliminarProducto = async (id: string): Promise<void> => {
    const { error } = await supabase.from('productos').delete().eq('id', id)
    if (error) throw error
    setProductos(prev => prev.filter(p => p.id !== id))
  }

  const validarStock = (items: StockValidationItem[]): { valido: boolean; errores: StockError[] } => {
    const errores: StockError[] = []
    for (const item of items) {
      const producto = productos.find(p => p.id === item.productoId)
      if (!producto) {
        errores.push({ productoId: item.productoId, mensaje: 'Producto no encontrado' })
        continue
      }
      if (producto.stock < item.cantidad) {
        errores.push({
          productoId: item.productoId,
          mensaje: `${producto.nombre}: stock insuficiente (disponible: ${producto.stock}, solicitado: ${item.cantidad})`
        })
      }
    }
    return { valido: errores.length === 0, errores }
  }

  const descontarStock = async (items: StockItem[]): Promise<void> => {
    const itemsParaRPC = items.map(item => ({
      producto_id: item.productoId || item.producto_id,
      cantidad: item.cantidad
    }))

    const { data, error } = await supabase.rpc('descontar_stock_atomico', {
      p_items: itemsParaRPC
    })

    if (error) {
      throw error
    }

    const rpcResult = data as DescontarStockRPCResult | null
    if (rpcResult && !rpcResult.success) {
      throw new Error(rpcResult.errores?.join(', ') || 'Error al descontar stock')
    }

    setProductos(prev => prev.map(p => {
      const item = items.find(i => (i.productoId || i.producto_id) === p.id)
      if (item) return { ...p, stock: p.stock - item.cantidad }
      return p
    }))
  }

  const restaurarStock = async (items: StockItem[]): Promise<void> => {
    const itemsParaRPC = items.map(item => ({
      producto_id: item.producto_id || item.productoId,
      cantidad: item.cantidad
    }))

    const { error } = await supabase.rpc('restaurar_stock_atomico', {
      p_items: itemsParaRPC
    })

    if (error) {
      throw error
    }

    setProductos(prev => prev.map(p => {
      const item = items.find(i => (i.producto_id || i.productoId) === p.id)
      if (item) return { ...p, stock: p.stock + item.cantidad }
      return p
    }))
  }

  const actualizarPreciosMasivo = async (productosData: PrecioMasivoItem[]): Promise<ActualizarPreciosResult> => {
    // Filtrar productos sin ID valido
    const productosValidos = productosData.filter(p => p.productoId != null)

    if (productosValidos.length === 0) {
      throw new Error('No hay productos validos para actualizar')
    }

    const productosParaRPC = productosValidos.map(p => ({
      producto_id: p.productoId,
      precio_neto: p.precioNeto || 0,
      imp_internos: p.impInternos || 0,
      precio_final: p.precioFinal || 0
    }))

    // Intentar usar la funcion RPC primero
    const { data, error } = await supabase.rpc('actualizar_precios_masivo', {
      p_productos: productosParaRPC
    })

    // Si la funcion RPC no existe o falla, usar fallback con updates individuales
    if (error) {
      logger.warn('RPC actualizar_precios_masivo fallo, usando fallback:', error.message)

      let actualizados = 0
      const errores: string[] = []

      for (const p of productosValidos) {
        const updateData: Record<string, number> = {
          precio: p.precioFinal || 0
        }
        // Solo incluir campos si tienen valor
        if (p.precioNeto) updateData.precio_sin_iva = p.precioNeto
        if (p.impInternos) updateData.impuestos_internos = p.impInternos

        const { error: updateError } = await supabase
          .from('productos')
          .update(updateData)
          .eq('id', p.productoId)

        if (updateError) {
          errores.push(`Error en producto ${p.productoId}: ${updateError.message}`)
        } else {
          actualizados++
        }
      }

      // Refrescar productos despues de actualizar
      await fetchProductos()

      if (errores.length > 0 && actualizados === 0) {
        throw new Error(errores.join(', '))
      }

      return { success: true, actualizados, errores }
    }

    // Verificar si la funcion RPC retorno exito
    const rpcResult = data as ActualizarPreciosResult | null
    if (rpcResult && rpcResult.success === false) {
      const erroresMsg = rpcResult.errores?.length > 0
        ? rpcResult.errores.join(', ')
        : 'Error en la actualizacion'
      throw new Error(erroresMsg)
    }

    // Refrescar productos despues de actualizar
    await fetchProductos()

    return rpcResult || { success: true, actualizados: productosValidos.length, errores: [] }
  }

  return {
    productos,
    loading,
    agregarProducto,
    actualizarProducto,
    eliminarProducto,
    validarStock,
    descontarStock,
    restaurarStock,
    actualizarPreciosMasivo,
    refetch: fetchProductos
  }
}

import { useState, useEffect } from 'react'
import { supabase, notifyError } from './base'

export function useProductos() {
  const [productos, setProductos] = useState([])
  const [loading, setLoading] = useState(true)

  const fetchProductos = async () => {
    setLoading(true)
    try {
      const { data, error } = await supabase.from('productos').select('*').order('nombre')
      if (error) throw error
      setProductos(data || [])
    } catch (error) {
      notifyError('Error al cargar productos: ' + error.message)
      setProductos([])
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { fetchProductos() }, [])

  const agregarProducto = async (producto) => {
    const { data, error } = await supabase.from('productos').insert([{
      nombre: producto.nombre,
      codigo: producto.codigo || null,
      precio: producto.precio,
      stock: producto.stock,
      stock_minimo: producto.stock_minimo !== undefined ? producto.stock_minimo : 10,
      categoria: producto.categoria || null,
      costo_sin_iva: producto.costo_sin_iva ? parseFloat(producto.costo_sin_iva) : null,
      costo_con_iva: producto.costo_con_iva ? parseFloat(producto.costo_con_iva) : null,
      impuestos_internos: producto.impuestos_internos ? parseFloat(producto.impuestos_internos) : null,
      precio_sin_iva: producto.precio_sin_iva ? parseFloat(producto.precio_sin_iva) : null
    }]).select().single()
    if (error) throw error
    setProductos(prev => [...prev, data].sort((a, b) => a.nombre.localeCompare(b.nombre)))
    return data
  }

  const actualizarProducto = async (id, producto) => {
    const { data, error } = await supabase.from('productos').update({
      nombre: producto.nombre,
      codigo: producto.codigo || null,
      precio: producto.precio,
      stock: producto.stock,
      stock_minimo: producto.stock_minimo !== undefined ? producto.stock_minimo : 10,
      categoria: producto.categoria || null,
      costo_sin_iva: producto.costo_sin_iva ? parseFloat(producto.costo_sin_iva) : null,
      costo_con_iva: producto.costo_con_iva ? parseFloat(producto.costo_con_iva) : null,
      impuestos_internos: producto.impuestos_internos ? parseFloat(producto.impuestos_internos) : null,
      precio_sin_iva: producto.precio_sin_iva ? parseFloat(producto.precio_sin_iva) : null
    }).eq('id', id).select().single()
    if (error) throw error
    setProductos(prev => prev.map(p => p.id === id ? data : p))
    return data
  }

  const eliminarProducto = async (id) => {
    const { error } = await supabase.from('productos').delete().eq('id', id)
    if (error) throw error
    setProductos(prev => prev.filter(p => p.id !== id))
  }

  const validarStock = (items) => {
    const errores = []
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

  const descontarStock = async (items) => {
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

    if (data && !data.success) {
      throw new Error(data.errores?.join(', ') || 'Error al descontar stock')
    }

    setProductos(prev => prev.map(p => {
      const item = items.find(i => (i.productoId || i.producto_id) === p.id)
      if (item) return { ...p, stock: p.stock - item.cantidad }
      return p
    }))
  }

  const restaurarStock = async (items) => {
    const itemsParaRPC = items.map(item => ({
      producto_id: item.producto_id || item.productoId,
      cantidad: item.cantidad
    }))

    const { data, error } = await supabase.rpc('restaurar_stock_atomico', {
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

  const actualizarPreciosMasivo = async (productosData) => {
    const productosParaRPC = productosData.map(p => ({
      producto_id: p.productoId,
      precio_neto: p.precioNeto,
      imp_internos: p.impInternos,
      precio_final: p.precioFinal
    }))

    const { data, error } = await supabase.rpc('actualizar_precios_masivo', {
      p_productos: productosParaRPC
    })

    if (error) throw error

    // Refrescar productos después de actualizar
    await fetchProductos()

    return data
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

import { useState, useEffect } from 'react'
import { supabase } from '../lib/supabase'

// ==================== CLIENTES ====================
export function useClientes() {
  const [clientes, setClientes] = useState([])
  const [loading, setLoading] = useState(true)

  const fetchClientes = async () => {
    setLoading(true)
    const { data, error } = await supabase
      .from('clientes')
      .select('*')
      .order('nombre_fantasia')
    
    if (error) {
      console.error('Error cargando clientes:', error)
    } else {
      setClientes(data || [])
    }
    setLoading(false)
  }

  useEffect(() => {
    fetchClientes()
  }, [])

  const agregarCliente = async (cliente) => {
    const { data, error } = await supabase
      .from('clientes')
      .insert([{
        nombre: cliente.nombre,
        nombre_fantasia: cliente.nombreFantasia,
        direccion: cliente.direccion,
        telefono: cliente.telefono || null,
        zona: cliente.zona || null
      }])
      .select()
      .single()
    
    if (error) throw error
    setClientes(prev => [...prev, data])
    return data
  }

  const actualizarCliente = async (id, cliente) => {
    const { data, error } = await supabase
      .from('clientes')
      .update({
        nombre: cliente.nombre,
        nombre_fantasia: cliente.nombreFantasia,
        direccion: cliente.direccion,
        telefono: cliente.telefono || null,
        zona: cliente.zona || null
      })
      .eq('id', id)
      .select()
      .single()
    
    if (error) throw error
    setClientes(prev => prev.map(c => c.id === id ? data : c))
    return data
  }

  const eliminarCliente = async (id) => {
    const { error } = await supabase
      .from('clientes')
      .delete()
      .eq('id', id)
    
    if (error) throw error
    setClientes(prev => prev.filter(c => c.id !== id))
  }

  return { 
    clientes, 
    loading, 
    agregarCliente, 
    actualizarCliente, 
    eliminarCliente, 
    refetch: fetchClientes 
  }
}

// ==================== PRODUCTOS ====================
export function useProductos() {
  const [productos, setProductos] = useState([])
  const [loading, setLoading] = useState(true)

  const fetchProductos = async () => {
    setLoading(true)
    const { data, error } = await supabase
      .from('productos')
      .select('*')
      .order('nombre')
    
    if (error) {
      console.error('Error cargando productos:', error)
    } else {
      setProductos(data || [])
    }
    setLoading(false)
  }

  useEffect(() => {
    fetchProductos()
  }, [])

  const agregarProducto = async (producto) => {
    const { data, error } = await supabase
      .from('productos')
      .insert([{
        nombre: producto.nombre,
        precio: producto.precio,
        stock: producto.stock,
        categoria: producto.categoria || null
      }])
      .select()
      .single()
    
    if (error) throw error
    setProductos(prev => [...prev, data])
    return data
  }

  const actualizarProducto = async (id, producto) => {
    const { data, error } = await supabase
      .from('productos')
      .update({
        nombre: producto.nombre,
        precio: producto.precio,
        stock: producto.stock,
        categoria: producto.categoria || null
      })
      .eq('id', id)
      .select()
      .single()
    
    if (error) throw error
    setProductos(prev => prev.map(p => p.id === id ? data : p))
    return data
  }

  const eliminarProducto = async (id) => {
    const { error } = await supabase
      .from('productos')
      .delete()
      .eq('id', id)
    
    if (error) throw error
    setProductos(prev => prev.filter(p => p.id !== id))
  }

  return { 
    productos, 
    loading, 
    agregarProducto, 
    actualizarProducto, 
    eliminarProducto, 
    refetch: fetchProductos 
  }
}

// ==================== PEDIDOS ====================
export function usePedidos() {
  const [pedidos, setPedidos] = useState([])
  const [loading, setLoading] = useState(true)

  const fetchPedidos = async () => {
    setLoading(true)
    const { data, error } = await supabase
      .from('pedidos')
      .select(`
        *,
        cliente:clientes(*),
        items:pedido_items(
          *,
          producto:productos(*)
        )
      `)
      .order('created_at', { ascending: false })
    
    if (error) {
      console.error('Error cargando pedidos:', error)
    } else {
      setPedidos(data || [])
    }
    setLoading(false)
  }

  useEffect(() => {
    fetchPedidos()
  }, [])

  const crearPedido = async (clienteId, items, total) => {
    const { data: pedido, error: pedidoError } = await supabase
      .from('pedidos')
      .insert([{
        cliente_id: clienteId,
        total: total,
        estado: 'pendiente'
      }])
      .select()
      .single()
    
    if (pedidoError) throw pedidoError

    const itemsParaInsertar = items.map(item => ({
      pedido_id: pedido.id,
      producto_id: item.productoId,
      cantidad: item.cantidad,
      precio_unitario: item.precioUnitario,
      subtotal: item.cantidad * item.precioUnitario
    }))

    const { error: itemsError } = await supabase
      .from('pedido_items')
      .insert(itemsParaInsertar)
    
    if (itemsError) throw itemsError

    await fetchPedidos()
    return pedido
  }

  const cambiarEstado = async (id, nuevoEstado) => {
    const { error } = await supabase
      .from('pedidos')
      .update({ estado: nuevoEstado })
      .eq('id', id)
    
    if (error) throw error
    setPedidos(prev => prev.map(p => p.id === id ? { ...p, estado: nuevoEstado } : p))
  }

  const eliminarPedido = async (id) => {
    const { error } = await supabase
      .from('pedidos')
      .delete()
      .eq('id', id)
    
    if (error) throw error
    setPedidos(prev => prev.filter(p => p.id !== id))
  }

  return { 
    pedidos, 
    loading, 
    crearPedido, 
    cambiarEstado, 
    eliminarPedido, 
    refetch: fetchPedidos 
  }
}

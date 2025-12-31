import { useState, useEffect, createContext, useContext } from 'react'
import { supabase } from '../lib/supabase'

// ==================== CONTEXTO DE AUTH ====================
const AuthContext = createContext({})

export function AuthProvider({ children }) {
  const [user, setUser] = useState(null)
  const [perfil, setPerfil] = useState(null)
  const [loading, setLoading] = useState(true)

  const fetchPerfil = async (userId) => {
    try {
      const { data, error } = await supabase
        .from('perfiles')
        .select('*')
        .eq('id', userId)
        .maybeSingle() 

      if (error) {
        console.error('Error al cargar perfil:', error.message)
      }
      
      if (data) {
        setPerfil(data)
      }
    } catch (err) {
      console.error('Error inesperado fetchPerfil:', err)
    }
  }

  useEffect(() => {
    let mounted = true

    const initAuth = async () => {
      supabase.auth.getSession().then(({ data }) => {
        if (mounted && data?.session?.user) {
          setUser(data.session.user)
          fetchPerfil(data.session.user.id)
        }
      }).catch(err => console.error("Error en getSession:", err))
    }

    initAuth()

    const { data: { subscription } } = supabase.auth.onAuthStateChange(async (event, session) => {
      if (!mounted) return

      if (event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED') {
        if (session?.user) {
          setUser(session.user)
          if (!perfil || perfil?.id !== session.user.id) {
            fetchPerfil(session.user.id)
          }
        }
        setLoading(false)
      } else if (event === 'SIGNED_OUT') {
        setUser(null)
        setPerfil(null)
        setLoading(false)
      } else if (event === 'INITIAL_SESSION') {
        setLoading(false)
      }
    })

    const safetyTimer = setTimeout(() => {
      if (mounted && loading) {
        console.warn("Watchdog: Forzando apertura de la App.")
        setLoading(false)
      }
    }, 2000)

    return () => {
      mounted = false
      clearTimeout(safetyTimer)
      subscription.unsubscribe()
    }
  }, [])

  const login = async (email, password) => {
    const { data, error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) throw error
    return data
  }

  const logout = async () => {
    const { error } = await supabase.auth.signOut()
    if (error) throw error
    setUser(null)
    setPerfil(null)
  }

  // Helpers para verificar rol
  const isAdmin = perfil?.rol === 'admin'
  const isPreventista = perfil?.rol === 'preventista'
  const isTransportista = perfil?.rol === 'transportista'

  return (
    <AuthContext.Provider value={{ 
      user, 
      perfil, 
      loading, 
      login, 
      logout, 
      isAdmin,
      isPreventista,
      isTransportista
    }}>
      {children}
    </AuthContext.Provider>
  )
}

export const useAuth = () => useContext(AuthContext)

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
      console.error('Error fetching clientes:', error)
    }
    setClientes(data || [])
    setLoading(false)
  }

  useEffect(() => { fetchClientes() }, [])

  const agregarCliente = async (cliente) => {
    const { data, error } = await supabase.from('clientes').insert([{
      nombre: cliente.nombre,
      nombre_fantasia: cliente.nombreFantasia,
      direccion: cliente.direccion,
      telefono: cliente.telefono || null,
      zona: cliente.zona || null
    }]).select().single()
    if (error) throw error
    setClientes(prev => [...prev, data].sort((a, b) => a.nombre_fantasia.localeCompare(b.nombre_fantasia)))
    return data
  }

  const actualizarCliente = async (id, cliente) => {
    const { data, error } = await supabase.from('clientes').update({
      nombre: cliente.nombre,
      nombre_fantasia: cliente.nombreFantasia,
      direccion: cliente.direccion,
      telefono: cliente.telefono || null,
      zona: cliente.zona || null
    }).eq('id', id).select().single()
    if (error) throw error
    setClientes(prev => prev.map(c => c.id === id ? data : c))
    return data
  }

  const eliminarCliente = async (id) => {
    const { error } = await supabase.from('clientes').delete().eq('id', id)
    if (error) throw error
    setClientes(prev => prev.filter(c => c.id !== id))
  }

  return { clientes, loading, agregarCliente, actualizarCliente, eliminarCliente, refetch: fetchClientes }
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
      console.error('Error fetching productos:', error)
    }
    setProductos(data || [])
    setLoading(false)
  }

  useEffect(() => { fetchProductos() }, [])

  const agregarProducto = async (producto) => {
    const { data, error } = await supabase.from('productos').insert([{
      nombre: producto.nombre,
      precio: producto.precio,
      stock: producto.stock,
      categoria: producto.categoria || null
    }]).select().single()
    if (error) throw error
    setProductos(prev => [...prev, data].sort((a, b) => a.nombre.localeCompare(b.nombre)))
    return data
  }

  const actualizarProducto = async (id, producto) => {
    const { data, error } = await supabase.from('productos').update({
      nombre: producto.nombre,
      precio: producto.precio,
      stock: producto.stock,
      categoria: producto.categoria || null
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

  return { productos, loading, agregarProducto, actualizarProducto, eliminarProducto, refetch: fetchProductos }
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
        items:pedido_items(*, producto:productos(*)),
        usuario:perfiles!pedidos_usuario_id_fkey(id, nombre, email),
        transportista:perfiles!pedidos_transportista_id_fkey(id, nombre, email)
      `)
      .order('created_at', { ascending: false })
    if (error) {
      console.error('Error fetching pedidos:', error)
    }
    setPedidos(data || [])
    setLoading(false)
  }

  useEffect(() => { fetchPedidos() }, [])

  const crearPedido = async (clienteId, items, total, usuarioId) => {
    const { data: pedido, error: pedidoError } = await supabase
      .from('pedidos')
      .insert([{ 
        cliente_id: clienteId, 
        total: total, 
        estado: 'pendiente',
        usuario_id: usuarioId
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

    const { error: itemsError } = await supabase.from('pedido_items').insert(itemsParaInsertar)
    if (itemsError) throw itemsError

    await fetchPedidos()
    return pedido
  }

  const cambiarEstado = async (id, nuevoEstado) => {
    const updateData = { estado: nuevoEstado }
    
    // Si se marca como entregado, guardar la fecha
    if (nuevoEstado === 'entregado') {
      updateData.fecha_entrega = new Date().toISOString()
    }
    // Si se desmarca de entregado, limpiar la fecha
    if (nuevoEstado !== 'entregado') {
      updateData.fecha_entrega = null
    }
    
    const { error } = await supabase.from('pedidos').update(updateData).eq('id', id)
    if (error) throw error
    setPedidos(prev => prev.map(p => p.id === id ? { ...p, ...updateData } : p))
  }

  const asignarTransportista = async (pedidoId, transportistaId) => {
    const { error } = await supabase
      .from('pedidos')
      .update({ 
        transportista_id: transportistaId,
        estado: transportistaId ? 'asignado' : 'pendiente'
      })
      .eq('id', pedidoId)
    if (error) throw error
    await fetchPedidos()
  }

  const eliminarPedido = async (id) => {
    // Primero eliminar los items del pedido
    const { error: itemsError } = await supabase
      .from('pedido_items')
      .delete()
      .eq('pedido_id', id)
    if (itemsError) throw itemsError

    // Luego eliminar el pedido
    const { error } = await supabase.from('pedidos').delete().eq('id', id)
    if (error) throw error
    setPedidos(prev => prev.filter(p => p.id !== id))
  }

  return { 
    pedidos, 
    loading, 
    crearPedido, 
    cambiarEstado, 
    asignarTransportista,
    eliminarPedido, 
    refetch: fetchPedidos 
  }
}

// ==================== USUARIOS ====================
export function useUsuarios() {
  const [usuarios, setUsuarios] = useState([])
  const [transportistas, setTransportistas] = useState([])
  const [loading, setLoading] = useState(true)

  const fetchUsuarios = async () => {
    setLoading(true)
    const { data, error } = await supabase
      .from('perfiles')
      .select('*')
      .order('nombre')
    if (error) {
      console.error('Error fetching usuarios:', error)
    }
    setUsuarios(data || [])
    // Filtrar transportistas activos para asignación
    setTransportistas((data || []).filter(u => u.rol === 'transportista' && u.activo))
    setLoading(false)
  }

  useEffect(() => { fetchUsuarios() }, [])

  const actualizarUsuario = async (id, datos) => {
    const { data, error } = await supabase.from('perfiles').update({ 
      nombre: datos.nombre, 
      rol: datos.rol, 
      activo: datos.activo 
    }).eq('id', id).select().single()
    if (error) throw error
    setUsuarios(prev => prev.map(u => u.id === id ? data : u))
    // Actualizar lista de transportistas
    setTransportistas(prev => {
      const updated = prev.filter(t => t.id !== id)
      if (data.rol === 'transportista' && data.activo) {
        return [...updated, data].sort((a, b) => a.nombre.localeCompare(b.nombre))
      }
      return updated
    })
    return data
  }

  return { usuarios, transportistas, loading, actualizarUsuario, refetch: fetchUsuarios }
}

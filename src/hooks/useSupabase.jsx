import { useState, useEffect, createContext, useContext, useRef } from 'react'
import { supabase } from '../lib/supabase'

// ==================== CONTEXTO DE AUTH ====================
const AuthContext = createContext({})

export function AuthProvider({ children }) {
  const [user, setUser] = useState(null)
  const [perfil, setPerfil] = useState(null)
  const [loading, setLoading] = useState(true)
  
  // REF: Evita que fetchPerfil se llame dos veces simultáneamente
  const fetchingRef = useRef(false)

  const fetchPerfil = async (userId) => {
    // Si ya hay una petición en curso, cancelamos esta nueva llamada
    if (fetchingRef.current) return
    fetchingRef.current = true

    try {
      console.log("⚡ Fetching perfil para:", userId)
      
      // Timeout de seguridad por si la BD no responde
      const controller = new AbortController()
      const timeoutId = setTimeout(() => controller.abort(), 5000)
      
      const { data, error } = await supabase
        .from('perfiles')
        .select('*')
        .eq('id', userId)
        .maybeSingle() // 'maybeSingle' es más seguro que 'single' (no explota si es null)
        .abortSignal(controller.signal)
      
      clearTimeout(timeoutId)
      
      if (error) {
        console.error('❌ Error Supabase al cargar perfil:', error.message)
        // No reseteamos perfil a null aquí para evitar parpadeos si es un error transitorio
      } 
      
      if (data) {
        console.log("✅ Perfil cargado:", data)
        setPerfil(data)
      }
    } catch (err) {
      console.error('Crash o Timeout en fetchPerfil:', err)
    } finally {
      fetchingRef.current = false
      setLoading(false)
    }
  }

  useEffect(() => {
    let mounted = true

    const initialize = async () => {
      try {
        // 1. Obtener sesión actual (sin forzar refresh agresivo)
        const { data: { session } } = await supabase.auth.getSession()

        if (session?.user) {
          if (mounted) setUser(session.user)
          // Solo buscamos perfil si tenemos usuario
          await fetchPerfil(session.user.id)
        } else {
          if (mounted) setLoading(false)
        }
      } catch (error) {
        console.error("Error inicializando auth:", error)
        if (mounted) setLoading(false)
      }
    }

    initialize()

    // 2. Escuchar cambios de autenticación
    const { data: { subscription } } = supabase.auth.onAuthStateChange(async (event, session) => {
      if (!mounted) return
      console.log('🔄 Auth Event:', event)
      
      if (event === 'SIGNED_OUT') {
        setUser(null)
        setPerfil(null)
        setLoading(false)
      } else if ((event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED') && session?.user) {
        // Solo actualizamos si el usuario cambió o si no tenemos perfil cargado
        if (session.user.id !== user?.id || !perfil) {
          setUser(session.user)
          await fetchPerfil(session.user.id)
        }
      }
    })

    return () => {
      mounted = false
      subscription.unsubscribe()
    }
  }, []) // Array vacío para ejecutar solo al montar

  const login = async (email, password) => {
    const { data, error } = await supabase.auth.signInWithPassword({
      email,
      password
    })
    if (error) throw error
    return data
  }

  const logout = async () => {
    const { error } = await supabase.auth.signOut()
    if (error) throw error
    setUser(null)
    setPerfil(null)
  }

  const isAdmin = perfil?.rol === 'admin'

  return (
    <AuthContext.Provider value={{ user, perfil, loading, login, logout, isAdmin }}>
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

// ==================== USUARIOS (solo admin) ====================
export function useUsuarios() {
  const [usuarios, setUsuarios] = useState([])
  const [loading, setLoading] = useState(true)

  const fetchUsuarios = async () => {
    setLoading(true)
    const { data, error } = await supabase
      .from('perfiles')
      .select('*')
      .order('nombre')
    
    if (error) {
      console.error('Error cargando usuarios:', error)
    } else {
      setUsuarios(data || [])
    }
    setLoading(false)
  }

  useEffect(() => {
    fetchUsuarios()
  }, [])

  const actualizarUsuario = async (id, datos) => {
    const { data, error } = await supabase
      .from('perfiles')
      .update({
        nombre: datos.nombre,
        rol: datos.rol,
        activo: datos.activo
      })
      .eq('id', id)
      .select()
      .single()
    
    if (error) throw error
    setUsuarios(prev => prev.map(u => u.id === id ? data : u))
    return data
  }

  return { 
    usuarios, 
    loading, 
    actualizarUsuario,
    refetch: fetchUsuarios 
  }
}

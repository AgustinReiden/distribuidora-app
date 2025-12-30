import { useState, useEffect, createContext, useContext } from 'react'
import { supabase } from '../lib/supabase'

// ==================== CONTEXTO DE AUTH ====================
const AuthContext = createContext({})

export function AuthProvider({ children }) {
  const [user, setUser] = useState(null)
  const [perfil, setPerfil] = useState(null)
  // Iniciamos en true, pero el Watchdog asegura que pase a false sí o sí
  const [loading, setLoading] = useState(true)

  // Función para buscar el perfil (se ejecuta en segundo plano, sin bloquear)
  const fetchPerfil = async (userId) => {
    try {
      const { data, error } = await supabase
        .from('perfiles')
        .select('*')
        .eq('id', userId)
        .maybeSingle() 

      if (error) {
        console.error('Error al cargar perfil (segundo plano):', error.message)
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

    // 1. INICIALIZACIÓN RÁPIDA (NON-BLOCKING)
    const initAuth = async () => {
      console.log("🚀 Iniciando sistema de Auth...")
      
      // Usamos .then() en lugar de await para no detener la ejecución si esto se cuelga
      supabase.auth.getSession().then(({ data }) => {
        if (mounted && data?.session?.user) {
          console.log("⚡ Sesión recuperada de caché")
          setUser(data.session.user)
          // Disparamos la búsqueda de perfil en paralelo
          fetchPerfil(data.session.user.id)
        }
      }).catch(err => console.error("Error silencioso en getSession:", err))
    }

    initAuth()

    // 2. ESCUCHADOR DE EVENTOS (La fuente de verdad)
    const { data: { subscription } } = supabase.auth.onAuthStateChange(async (event, session) => {
      if (!mounted) return
      console.log('🔄 Auth Event:', event)

      if (event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED') {
        if (session?.user) {
          setUser(session.user)
          // Si el usuario cambió o no tenemos perfil, lo buscamos
          if (!perfil || perfil?.id !== session.user.id) {
            fetchPerfil(session.user.id)
          }
        }
        // ¡CRÍTICO! Si hay login, quitamos el loading INMEDIATAMENTE.
        // No esperamos a que termine fetchPerfil.
        setLoading(false)
      } else if (event === 'SIGNED_OUT') {
        setUser(null)
        setPerfil(null)
        setLoading(false)
      } else if (event === 'INITIAL_SESSION') {
        // Evento de inicialización, también desbloquea
        setLoading(false)
      }
    })

    // 3. WATCHDOG (EL SALVAVIDAS) 🚑
    // Si por alguna razón (bug de Chrome, red corporativa, etc) 
    // los eventos no disparan en 2 segundos, forzamos la apertura.
    const safetyTimer = setTimeout(() => {
      if (mounted && loading) {
        console.warn("⚠️ Watchdog: La carga tardó mucho. Forzando apertura de la App.")
        setLoading(false)
      }
    }, 2000)

    return () => {
      mounted = false
      clearTimeout(safetyTimer)
      subscription.unsubscribe()
    }
  }, []) // Array vacío: se ejecuta solo al montar

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

  // Helper para verificar rol
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
    const { data, error } = await supabase.from('clientes').select('*').order('nombre_fantasia')
    if (!error) setClientes(data || [])
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
    setClientes(prev => [...prev, data])
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
    const { data, error } = await supabase.from('productos').select('*').order('nombre')
    if (!error) setProductos(data || [])
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
    setProductos(prev => [...prev, data])
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
    const { data, error } = await supabase.from('pedidos').select(`*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))`).order('created_at', { ascending: false })
    if (!error) setPedidos(data || [])
    setLoading(false)
  }

  useEffect(() => { fetchPedidos() }, [])

  const crearPedido = async (clienteId, items, total) => {
    const { data: pedido, error: pedidoError } = await supabase.from('pedidos').insert([{ cliente_id: clienteId, total: total, estado: 'pendiente' }]).select().single()
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
    const { error } = await supabase.from('pedidos').update({ estado: nuevoEstado }).eq('id', id)
    if (error) throw error
    setPedidos(prev => prev.map(p => p.id === id ? { ...p, estado: nuevoEstado } : p))
  }

  const eliminarPedido = async (id) => {
    const { error } = await supabase.from('pedidos').delete().eq('id', id)
    if (error) throw error
    setPedidos(prev => prev.filter(p => p.id !== id))
  }

  return { pedidos, loading, crearPedido, cambiarEstado, eliminarPedido, refetch: fetchPedidos }
}

// ==================== USUARIOS ====================
export function useUsuarios() {
  const [usuarios, setUsuarios] = useState([])
  const [loading, setLoading] = useState(true)

  const fetchUsuarios = async () => {
    setLoading(true)
    const { data, error } = await supabase.from('perfiles').select('*').order('nombre')
    if (!error) setUsuarios(data || [])
    setLoading(false)
  }

  useEffect(() => { fetchUsuarios() }, [])

  const actualizarUsuario = async (id, datos) => {
    const { data, error } = await supabase.from('perfiles').update({ nombre: datos.nombre, rol: datos.rol, activo: datos.activo }).eq('id', id).select().single()
    if (error) throw error
    setUsuarios(prev => prev.map(u => u.id === id ? data : u))
    return data
  }

  return { usuarios, loading, actualizarUsuario, refetch: fetchUsuarios }
}

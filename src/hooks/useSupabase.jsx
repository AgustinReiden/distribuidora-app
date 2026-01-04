import { useState, useEffect, createContext, useContext } from 'react'
import { supabase } from '../lib/supabase'
import * as XLSX from 'xlsx'

const AuthContext = createContext({})

// Sistema de notificación de errores centralizado
let errorNotifier = null
export const setErrorNotifier = (notifier) => { errorNotifier = notifier }
const notifyError = (message) => { if (errorNotifier) errorNotifier(message); else console.error(message) }

export function AuthProvider({ children }) {
  const [user, setUser] = useState(null)
  const [perfil, setPerfil] = useState(null)
  const [loading, setLoading] = useState(true)

  const fetchPerfil = async (userId) => {
    try {
      const { data, error } = await supabase.from('perfiles').select('*').eq('id', userId).maybeSingle()
      if (error) console.error('Error al cargar perfil:', error.message)
      if (data) setPerfil(data)
    } catch (err) { console.error('Error inesperado fetchPerfil:', err) }
  }

  useEffect(() => {
    let mounted = true
    supabase.auth.getSession().then(({ data }) => {
      if (mounted && data?.session?.user) { setUser(data.session.user); fetchPerfil(data.session.user.id) }
    }).catch(err => console.error("Error en getSession:", err))

    const { data: { subscription } } = supabase.auth.onAuthStateChange(async (event, session) => {
      if (!mounted) return
      if (event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED') {
        if (session?.user) { setUser(session.user); if (!perfil || perfil?.id !== session.user.id) fetchPerfil(session.user.id) }
        setLoading(false)
      } else if (event === 'SIGNED_OUT') { setUser(null); setPerfil(null); setLoading(false) }
      else if (event === 'INITIAL_SESSION') setLoading(false)
    })
    const safetyTimer = setTimeout(() => { if (mounted && loading) { console.warn("Watchdog: Forzando apertura."); setLoading(false) } }, 2000)
    return () => { mounted = false; clearTimeout(safetyTimer); subscription.unsubscribe() }
  }, [])

  const login = async (email, password) => { const { data, error } = await supabase.auth.signInWithPassword({ email, password }); if (error) throw error; return data }
  const logout = async () => { const { error } = await supabase.auth.signOut(); if (error) throw error; setUser(null); setPerfil(null) }

  return <AuthContext.Provider value={{ user, perfil, loading, login, logout, isAdmin: perfil?.rol === 'admin', isPreventista: perfil?.rol === 'preventista', isTransportista: perfil?.rol === 'transportista' }}>{children}</AuthContext.Provider>
}

export const useAuth = () => useContext(AuthContext)

export function useClientes() {
  const [clientes, setClientes] = useState([])
  const [loading, setLoading] = useState(true)

  const fetchClientes = async () => {
    setLoading(true)
    try {
      const { data, error } = await supabase.from('clientes').select('*').order('nombre_fantasia')
      if (error) throw error
      setClientes(data || [])
    } catch (error) {
      console.error('Error fetching clientes:', error)
      notifyError('Error al cargar clientes: ' + error.message)
      setClientes([])
    } finally {
      setLoading(false)
    }
  }
  useEffect(() => { fetchClientes() }, [])

  const agregarCliente = async (cliente) => {
    const { data, error } = await supabase.from('clientes').insert([{
      nombre: cliente.nombre,
      nombre_fantasia: cliente.nombreFantasia,
      direccion: cliente.direccion,
      latitud: cliente.latitud || null,
      longitud: cliente.longitud || null,
      telefono: cliente.telefono || null,
      zona: cliente.zona || null,
      limite_credito: cliente.limiteCredito ? parseFloat(cliente.limiteCredito) : 0,
      dias_credito: cliente.diasCredito ? parseInt(cliente.diasCredito) : 30
    }]).select().single()
    if (error) throw error
    setClientes(prev => [...prev, data].sort((a, b) => a.nombre_fantasia.localeCompare(b.nombre_fantasia))); return data
  }
  const actualizarCliente = async (id, cliente) => {
    const updateData = {
      nombre: cliente.nombre,
      nombre_fantasia: cliente.nombreFantasia,
      direccion: cliente.direccion,
      latitud: cliente.latitud || null,
      longitud: cliente.longitud || null,
      telefono: cliente.telefono || null,
      zona: cliente.zona || null
    }
    // Only update credit fields if provided (to avoid overwriting with undefined)
    if (cliente.limiteCredito !== undefined) updateData.limite_credito = parseFloat(cliente.limiteCredito) || 0
    if (cliente.diasCredito !== undefined) updateData.dias_credito = parseInt(cliente.diasCredito) || 30

    const { data, error } = await supabase.from('clientes').update(updateData).eq('id', id).select().single()
    if (error) throw error; setClientes(prev => prev.map(c => c.id === id ? data : c)); return data
  }
  const eliminarCliente = async (id) => { const { error } = await supabase.from('clientes').delete().eq('id', id); if (error) throw error; setClientes(prev => prev.filter(c => c.id !== id)) }
  return { clientes, loading, agregarCliente, actualizarCliente, eliminarCliente, refetch: fetchClientes }
}

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
      console.error('Error fetching productos:', error)
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

  const eliminarProducto = async (id) => { const { error } = await supabase.from('productos').delete().eq('id', id); if (error) throw error; setProductos(prev => prev.filter(p => p.id !== id)) }

  const validarStock = (items) => {
    const errores = []
    for (const item of items) {
      const producto = productos.find(p => p.id === item.productoId)
      if (!producto) { errores.push({ productoId: item.productoId, mensaje: 'Producto no encontrado' }); continue }
      if (producto.stock < item.cantidad) errores.push({ productoId: item.productoId, mensaje: `${producto.nombre}: stock insuficiente (disponible: ${producto.stock}, solicitado: ${item.cantidad})` })
    }
    return { valido: errores.length === 0, errores }
  }

  const descontarStock = async (items) => {
    // Usar función atómica RPC para evitar race conditions
    const itemsParaRPC = items.map(item => ({
      producto_id: item.productoId || item.producto_id,
      cantidad: item.cantidad
    }))

    const { data, error } = await supabase.rpc('descontar_stock_atomico', {
      p_items: itemsParaRPC
    })

    if (error) {
      // Fallback al método anterior si la función RPC no existe
      if (error.message.includes('function') && error.message.includes('does not exist')) {
        console.warn('RPC descontar_stock_atomico no disponible, usando método legacy')
        for (const item of items) {
          const producto = productos.find(p => p.id === item.productoId)
          if (!producto) continue
          const nuevoStock = producto.stock - item.cantidad
          const { error: updateError } = await supabase.from('productos').update({ stock: nuevoStock }).eq('id', item.productoId)
          if (updateError) throw updateError
          setProductos(prev => prev.map(p => p.id === item.productoId ? { ...p, stock: nuevoStock } : p))
        }
        return
      }
      throw error
    }

    if (data && !data.success) {
      throw new Error(data.errores?.join(', ') || 'Error al descontar stock')
    }

    // Actualizar estado local
    setProductos(prev => prev.map(p => {
      const item = items.find(i => (i.productoId || i.producto_id) === p.id)
      if (item) return { ...p, stock: p.stock - item.cantidad }
      return p
    }))
  }

  const restaurarStock = async (items) => {
    // Usar función atómica RPC
    const itemsParaRPC = items.map(item => ({
      producto_id: item.producto_id || item.productoId,
      cantidad: item.cantidad
    }))

    const { data, error } = await supabase.rpc('restaurar_stock_atomico', {
      p_items: itemsParaRPC
    })

    if (error) {
      // Fallback al método anterior si la función RPC no existe
      if (error.message.includes('function') && error.message.includes('does not exist')) {
        console.warn('RPC restaurar_stock_atomico no disponible, usando método legacy')
        for (const item of items) {
          const producto = productos.find(p => p.id === item.producto_id || p.id === item.productoId)
          if (!producto) continue
          const nuevoStock = producto.stock + item.cantidad
          const { error: updateError } = await supabase.from('productos').update({ stock: nuevoStock }).eq('id', producto.id)
          if (updateError) throw updateError
          setProductos(prev => prev.map(p => p.id === producto.id ? { ...p, stock: nuevoStock } : p))
        }
        return
      }
      throw error
    }

    // Actualizar estado local
    setProductos(prev => prev.map(p => {
      const item = items.find(i => (i.producto_id || i.productoId) === p.id)
      if (item) return { ...p, stock: p.stock + item.cantidad }
      return p
    }))
  }

  return { productos, loading, agregarProducto, actualizarProducto, eliminarProducto, validarStock, descontarStock, restaurarStock, refetch: fetchProductos }
}

export function usePedidos() {
  const [pedidos, setPedidos] = useState([])
  const [loading, setLoading] = useState(true)
  const [filtros, setFiltros] = useState({ fechaDesde: null, fechaHasta: null, estado: 'todos', busqueda: '' })

  const fetchPedidos = async () => {
    setLoading(true)
    try {
      const { data, error } = await supabase.from('pedidos').select(`*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))`).order('created_at', { ascending: false })
      if (error) { console.error('Error fetching pedidos:', error); setPedidos([]); setLoading(false); return }
      const pedidosCompletos = await Promise.all((data || []).map(async (pedido) => {
        let usuario = null, transportista = null
        if (pedido.usuario_id) { const { data: u } = await supabase.from('perfiles').select('id, nombre, email').eq('id', pedido.usuario_id).maybeSingle(); usuario = u }
        if (pedido.transportista_id) { const { data: t } = await supabase.from('perfiles').select('id, nombre, email').eq('id', pedido.transportista_id).maybeSingle(); transportista = t }
        return { ...pedido, usuario, transportista }
      }))
      setPedidos(pedidosCompletos)
    } catch (error) {
      console.error('Error fetching pedidos:', error)
      notifyError('Error al cargar pedidos: ' + error.message)
      setPedidos([])
    } finally {
      setLoading(false)
    }
  }
  useEffect(() => { fetchPedidos() }, [])

  const fetchHistorialPedido = async (pedidoId) => {
    try {
      const { data, error } = await supabase
        .from('pedido_historial')
        .select('*, usuario:perfiles(id, nombre, email)')
        .eq('pedido_id', pedidoId)
        .order('created_at', { ascending: false })
      if (error) throw error
      return data || []
    } catch (error) {
      console.error('Error fetching historial:', error)
      notifyError('Error al cargar historial del pedido: ' + error.message)
      return []
    }
  }

  const pedidosFiltrados = () => pedidos.filter(p => {
    if (filtros.estado !== 'todos' && p.estado !== filtros.estado) return false
    // Comparar solo la parte de fecha (YYYY-MM-DD) para evitar problemas de zona horaria
    const fechaPedido = p.created_at ? p.created_at.split('T')[0] : null
    if (filtros.fechaDesde && fechaPedido && fechaPedido < filtros.fechaDesde) return false
    if (filtros.fechaHasta && fechaPedido && fechaPedido > filtros.fechaHasta) return false
    return true
  })

  const crearPedido = async (clienteId, items, total, usuarioId, descontarStockFn, notas = '', formaPago = 'efectivo', estadoPago = 'pendiente') => {
    // Usar función atómica RPC para crear pedido + items + descontar stock en una transacción
    const itemsParaRPC = items.map(item => ({
      producto_id: item.productoId,
      cantidad: item.cantidad,
      precio_unitario: item.precioUnitario
    }))

    // Orden corregido: p_items DEBE estar en 4ta posición (después de p_usuario_id, antes de parámetros con DEFAULT)
    // En PostgreSQL, parámetros sin DEFAULT deben ir antes de parámetros con DEFAULT
    const { data, error } = await supabase.rpc('crear_pedido_completo', {
      p_cliente_id: clienteId,
      p_total: total,
      p_usuario_id: usuarioId,
      p_items: itemsParaRPC,
      p_notas: notas || null,
      p_forma_pago: formaPago || 'efectivo',
      p_estado_pago: estadoPago || 'pendiente'
    })

    if (error) {
      // Fallback al método anterior si la función RPC no existe
      if (error.message.includes('function') && error.message.includes('does not exist')) {
        console.warn('RPC crear_pedido_completo no disponible, usando método legacy')
        const { data: pedido, error: pedidoError } = await supabase.from('pedidos').insert([{
          cliente_id: clienteId,
          total,
          estado: 'pendiente',
          usuario_id: usuarioId,
          stock_descontado: true,
          notas: notas || null,
          forma_pago: formaPago || 'efectivo',
          estado_pago: estadoPago || 'pendiente'
        }]).select().single()
        if (pedidoError) throw pedidoError
        const itemsParaInsertar = items.map(item => ({ pedido_id: pedido.id, producto_id: item.productoId, cantidad: item.cantidad, precio_unitario: item.precioUnitario, subtotal: item.cantidad * item.precioUnitario }))
        const { error: itemsError } = await supabase.from('pedido_items').insert(itemsParaInsertar)
        if (itemsError) throw itemsError
        if (descontarStockFn) await descontarStockFn(items)
        await fetchPedidos(); return pedido
      }
      throw error
    }

    if (!data.success) {
      throw new Error(data.errores?.join(', ') || 'Error al crear pedido')
    }

    await fetchPedidos()
    return { id: data.pedido_id }
  }

  const cambiarEstado = async (id, nuevoEstado) => {
    const updateData = { estado: nuevoEstado }
    if (nuevoEstado === 'entregado') updateData.fecha_entrega = new Date().toISOString(); else updateData.fecha_entrega = null
    const { error } = await supabase.from('pedidos').update(updateData).eq('id', id); if (error) throw error
    setPedidos(prev => prev.map(p => p.id === id ? { ...p, ...updateData } : p))
  }

  const asignarTransportista = async (pedidoId, transportistaId, cambiarEstado = false) => {
    // Solo actualizar el transportista_id, NO cambiar el estado automáticamente
    // Esto permite asignar un transportista a un pedido que aún está pendiente de preparar
    const updateData = { transportista_id: transportistaId || null };

    // Solo cambiar estado si se indica explícitamente o si se desasigna el transportista
    if (cambiarEstado && transportistaId) {
      updateData.estado = 'asignado';
    } else if (!transportistaId) {
      // Si se desasigna el transportista, volver a pendiente solo si estaba asignado
      // Esto se maneja en el componente
    }

    const { error } = await supabase.from('pedidos').update(updateData).eq('id', pedidoId);
    if (error) throw error;
    await fetchPedidos();
  }

  const eliminarPedido = async (id, restaurarStockFn) => {
    const pedido = pedidos.find(p => p.id === id)
    const restaurarStock = pedido?.stock_descontado ?? true

    // Usar función atómica RPC para eliminar pedido + items + restaurar stock en una transacción
    const { data, error } = await supabase.rpc('eliminar_pedido_completo', {
      p_pedido_id: id,
      p_restaurar_stock: restaurarStock
    })

    if (error) {
      // Fallback al método anterior si la función RPC no existe
      if (error.message.includes('function') && error.message.includes('does not exist')) {
        console.warn('RPC eliminar_pedido_completo no disponible, usando método legacy')
        if (pedido?.stock_descontado && pedido?.items && restaurarStockFn) await restaurarStockFn(pedido.items)
        await supabase.from('pedido_historial').delete().eq('pedido_id', id)
        await supabase.from('pedido_items').delete().eq('pedido_id', id)
        const { error: deleteError } = await supabase.from('pedidos').delete().eq('id', id)
        if (deleteError) throw deleteError
        setPedidos(prev => prev.filter(p => p.id !== id))
        return
      }
      throw error
    }

    if (!data.success) {
      throw new Error(data.error || 'Error al eliminar pedido')
    }

    setPedidos(prev => prev.filter(p => p.id !== id))
  }

  const actualizarNotasPedido = async (pedidoId, notas) => {
    const { error } = await supabase.from('pedidos').update({ notas }).eq('id', pedidoId)
    if (error) throw error
    setPedidos(prev => prev.map(p => p.id === pedidoId ? { ...p, notas } : p))
  }

  const actualizarEstadoPago = async (pedidoId, estadoPago) => {
    const { error } = await supabase.from('pedidos').update({ estado_pago: estadoPago }).eq('id', pedidoId)
    if (error) throw error
    setPedidos(prev => prev.map(p => p.id === pedidoId ? { ...p, estado_pago: estadoPago } : p))
  }

  const actualizarFormaPago = async (pedidoId, formaPago) => {
    const { error } = await supabase.from('pedidos').update({ forma_pago: formaPago }).eq('id', pedidoId)
    if (error) throw error
    setPedidos(prev => prev.map(p => p.id === pedidoId ? { ...p, forma_pago: formaPago } : p))
  }

  const actualizarOrdenEntrega = async (ordenOptimizado) => {
    // ordenOptimizado es un array de { pedido_id, orden }
    if (!ordenOptimizado || ordenOptimizado.length === 0) return

    // Intentar usar la funcion RPC primero (mas confiable)
    const { error: rpcError } = await supabase.rpc('actualizar_orden_entrega_batch', {
      ordenes: ordenOptimizado.map(item => ({
        pedido_id: item.pedido_id,
        orden: item.orden
      }))
    })

    if (rpcError) {
      // Si la RPC no existe o falla, intentar update directo
      console.warn('RPC no disponible, usando update directo:', rpcError.message)

      // Usar raw SQL query a través de rpc genérico
      for (const item of ordenOptimizado) {
        const { error } = await supabase
          .from('pedidos')
          .update({ orden_entrega: item.orden })
          .eq('id', item.pedido_id)

        if (error) {
          // Si el error es de schema cache, refrescar y reintentar
          if (error.message.includes('schema cache') || error.message.includes('orden_entrega')) {
            console.error('Error de schema cache. La columna orden_entrega puede no existir en la base de datos.')
            console.error('Ejecute la migracion: migrations/004_add_orden_entrega.sql')
            throw new Error('La columna orden_entrega no existe en la base de datos. Contacte al administrador para ejecutar la migracion pendiente.')
          }
          throw error
        }
      }
    }

    // Actualizar estado local
    setPedidos(prev => prev.map(p => {
      const ordenItem = ordenOptimizado.find(o => o.pedido_id === p.id)
      if (ordenItem) {
        return { ...p, orden_entrega: ordenItem.orden }
      }
      return p
    }))
  }

  const limpiarOrdenEntrega = async (transportistaId) => {
    // Limpiar el orden de entrega de todos los pedidos de un transportista
    const { error } = await supabase
      .from('pedidos')
      .update({ orden_entrega: null })
      .eq('transportista_id', transportistaId)
    if (error) throw error

    // Actualizar estado local
    setPedidos(prev => prev.map(p =>
      p.transportista_id === transportistaId ? { ...p, orden_entrega: null } : p
    ))
  }

  return {
    pedidos,
    pedidosFiltrados,
    loading,
    crearPedido,
    cambiarEstado,
    asignarTransportista,
    eliminarPedido,
    actualizarNotasPedido,
    actualizarEstadoPago,
    actualizarFormaPago,
    actualizarOrdenEntrega,
    limpiarOrdenEntrega,
    fetchHistorialPedido,
    filtros,
    setFiltros,
    refetch: fetchPedidos
  }
}

export function useUsuarios() {
  const [usuarios, setUsuarios] = useState([])
  const [transportistas, setTransportistas] = useState([])
  const [loading, setLoading] = useState(true)

  const fetchUsuarios = async () => {
    setLoading(true)
    try {
      const { data, error } = await supabase.from('perfiles').select('*').order('nombre')
      if (error) throw error
      setUsuarios(data || [])
      setTransportistas((data || []).filter(u => u.rol === 'transportista' && u.activo))
    } catch (error) {
      console.error('Error fetching usuarios:', error)
      notifyError('Error al cargar usuarios: ' + error.message)
      setUsuarios([])
      setTransportistas([])
    } finally {
      setLoading(false)
    }
  }
  useEffect(() => { fetchUsuarios() }, [])

  const actualizarUsuario = async (id, datos) => {
    const { data, error } = await supabase.from('perfiles').update({ nombre: datos.nombre, rol: datos.rol, activo: datos.activo }).eq('id', id).select().single()
    if (error) throw error; setUsuarios(prev => prev.map(u => u.id === id ? data : u))
    setTransportistas(prev => { const updated = prev.filter(t => t.id !== id); if (data.rol === 'transportista' && data.activo) return [...updated, data].sort((a, b) => a.nombre.localeCompare(b.nombre)); return updated })
    return data
  }
  return { usuarios, transportistas, loading, actualizarUsuario, refetch: fetchUsuarios }
}

export function useDashboard(usuarioFiltro = null) {
  // usuarioFiltro: si se pasa un ID de usuario, filtra los pedidos solo por ese usuario (para preventistas)
  const [metricas, setMetricas] = useState({
    ventasPeriodo: 0,
    pedidosPeriodo: 0,
    productosMasVendidos: [],
    clientesMasActivos: [],
    pedidosPorEstado: { pendiente: 0, en_preparacion: 0, asignado: 0, entregado: 0 },
    ventasPorDia: []
  })
  const [loading, setLoading] = useState(true)
  const [loadingReporte, setLoadingReporte] = useState(false)
  const [reportePreventistas, setReportePreventistas] = useState([])
  const [reporteInicializado, setReporteInicializado] = useState(false)
  const [filtroPeriodo, setFiltroPeriodo] = useState('mes') // 'hoy', 'semana', 'mes', 'anio', 'historico', 'personalizado'
  const [fechaDesde, setFechaDesde] = useState(null)
  const [fechaHasta, setFechaHasta] = useState(null)

  const calcularMetricas = async (periodo = filtroPeriodo, fDesde = fechaDesde, fHasta = fechaHasta) => {
    setLoading(true)
    try {
      // Construir query base
      let query = supabase
        .from('pedidos')
        .select(`*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))`)

      // Si hay filtro de usuario (preventista), filtrar por usuario_id
      if (usuarioFiltro) {
        query = query.eq('usuario_id', usuarioFiltro)
      }

      const { data: todosPedidos, error: errorTodos } = await query.order('created_at', { ascending: false })

      if (errorTodos) throw errorTodos
      if (!todosPedidos) { setLoading(false); return }

      // Calcular fechas límite según el período seleccionado
      const hoy = new Date()
      const hoyStr = hoy.toISOString().split('T')[0]
      let fechaInicioStr = null

      switch (periodo) {
        case 'hoy':
          fechaInicioStr = hoyStr
          break
        case 'semana':
          const hace7Dias = new Date()
          hace7Dias.setDate(hace7Dias.getDate() - 7)
          fechaInicioStr = hace7Dias.toISOString().split('T')[0]
          break
        case 'mes':
          const inicioMes = new Date(hoy.getFullYear(), hoy.getMonth(), 1)
          fechaInicioStr = inicioMes.toISOString().split('T')[0]
          break
        case 'anio':
          const inicioAnio = new Date(hoy.getFullYear(), 0, 1)
          fechaInicioStr = inicioAnio.toISOString().split('T')[0]
          break
        case 'personalizado':
          fechaInicioStr = fDesde || null
          break
        case 'historico':
        default:
          fechaInicioStr = null
          break
      }

      // Filtrar pedidos según el período
      let pedidosFiltrados = todosPedidos
      if (fechaInicioStr) {
        pedidosFiltrados = todosPedidos.filter(p => p.created_at?.split('T')[0] >= fechaInicioStr)
      }
      if (periodo === 'personalizado' && fHasta) {
        pedidosFiltrados = pedidosFiltrados.filter(p => p.created_at?.split('T')[0] <= fHasta)
      }

      // Top productos (del período filtrado)
      const productosVendidos = {}
      pedidosFiltrados.forEach(p => p.items?.forEach(i => {
        const id = i.producto_id
        if (!productosVendidos[id]) productosVendidos[id] = { id, nombre: i.producto?.nombre || 'N/A', cantidad: 0 }
        productosVendidos[id].cantidad += i.cantidad
      }))
      const topProductos = Object.values(productosVendidos).sort((a, b) => b.cantidad - a.cantidad).slice(0, 5)

      // Top clientes (del período filtrado)
      const clientesActivos = {}
      pedidosFiltrados.forEach(p => {
        const id = p.cliente_id
        if (!clientesActivos[id]) clientesActivos[id] = { id, nombre: p.cliente?.nombre_fantasia || 'N/A', total: 0, pedidos: 0 }
        clientesActivos[id].total += p.total || 0
        clientesActivos[id].pedidos += 1
      })
      const topClientes = Object.values(clientesActivos).sort((a, b) => b.total - a.total).slice(0, 5)

      // Ventas por día (últimos 7 días, siempre)
      const ventasPorDia = []
      for (let i = 6; i >= 0; i--) {
        const fecha = new Date()
        fecha.setDate(fecha.getDate() - i)
        const fechaStr = fecha.toISOString().split('T')[0]
        const pedidosDia = todosPedidos.filter(p => p.created_at?.split('T')[0] === fechaStr)
        ventasPorDia.push({
          dia: fecha.toLocaleDateString('es-AR', { weekday: 'short' }),
          ventas: pedidosDia.reduce((s, p) => s + (p.total || 0), 0),
          pedidos: pedidosDia.length
        })
      }

      // Pedidos por estado (TODOS los pedidos activos, sin filtro de fecha)
      const pedidosPorEstado = {
        pendiente: todosPedidos.filter(p => p.estado === 'pendiente').length,
        en_preparacion: todosPedidos.filter(p => p.estado === 'en_preparacion').length,
        asignado: todosPedidos.filter(p => p.estado === 'asignado').length,
        entregado: todosPedidos.filter(p => p.estado === 'entregado').length
      }

      setMetricas({
        ventasPeriodo: pedidosFiltrados.reduce((s, p) => s + (p.total || 0), 0),
        pedidosPeriodo: pedidosFiltrados.length,
        productosMasVendidos: topProductos,
        clientesMasActivos: topClientes,
        pedidosPorEstado,
        ventasPorDia
      })
    } catch (error) {
      console.error('Error calculando métricas:', error)
      notifyError('Error al calcular métricas: ' + error.message)
    } finally {
      setLoading(false)
    }
  }

  const cambiarPeriodo = (nuevoPeriodo, fDesde = null, fHasta = null) => {
    setFiltroPeriodo(nuevoPeriodo)
    setFechaDesde(fDesde)
    setFechaHasta(fHasta)
    calcularMetricas(nuevoPeriodo, fDesde, fHasta)
  }
  const calcularReportePreventistas = async (fechaDesde = null, fechaHasta = null) => {
    setLoadingReporte(true)
    try {
      // Construir query base
      let query = supabase.from('pedidos').select(`*, items:pedido_items(*)`)

      // Aplicar filtros de fecha usando formato ISO directo
      // PostgreSQL puede comparar timestamps con strings 'YYYY-MM-DD'
      if (fechaDesde) {
        query = query.gte('created_at', `${fechaDesde}T00:00:00`)
      }
      if (fechaHasta) {
        query = query.lte('created_at', `${fechaHasta}T23:59:59`)
      }

      const { data: pedidos, error } = await query
      if (error) throw error

      if (!pedidos || pedidos.length === 0) {
        setReportePreventistas([])
        setReporteInicializado(true)
        return
      }

      // Obtener usuarios únicos de los pedidos
      const usuarioIds = [...new Set(pedidos.map(p => p.usuario_id).filter(Boolean))]
      const { data: usuarios } = await supabase.from('perfiles').select('id, nombre, email').in('id', usuarioIds)
      const usuariosMap = {}
      ;(usuarios || []).forEach(u => { usuariosMap[u.id] = u })

      const reportePorPreventista = {}

      pedidos.forEach(pedido => {
        const usuarioId = pedido.usuario_id
        if (!usuarioId) return

        const usuario = usuariosMap[usuarioId]
        const usuarioNombre = usuario?.nombre || 'Usuario desconocido'

        if (!reportePorPreventista[usuarioId]) {
          reportePorPreventista[usuarioId] = {
            id: usuarioId,
            nombre: usuarioNombre,
            email: usuario?.email || 'N/A',
            totalVentas: 0,
            cantidadPedidos: 0,
            pedidosPendientes: 0,
            pedidosAsignados: 0,
            pedidosEntregados: 0,
            totalPagado: 0,
            totalPendiente: 0
          }
        }

        reportePorPreventista[usuarioId].totalVentas += pedido.total || 0
        reportePorPreventista[usuarioId].cantidadPedidos += 1

        if (pedido.estado === 'pendiente') reportePorPreventista[usuarioId].pedidosPendientes += 1
        if (pedido.estado === 'asignado') reportePorPreventista[usuarioId].pedidosAsignados += 1
        if (pedido.estado === 'entregado') reportePorPreventista[usuarioId].pedidosEntregados += 1

        if (pedido.estado_pago === 'pagado') reportePorPreventista[usuarioId].totalPagado += pedido.total || 0
        else if (pedido.estado_pago === 'pendiente') reportePorPreventista[usuarioId].totalPendiente += pedido.total || 0
      })

      const reporteArray = Object.values(reportePorPreventista).sort((a, b) => b.totalVentas - a.totalVentas)
      setReportePreventistas(reporteArray)
      setReporteInicializado(true)
    } catch (error) {
      console.error('Error calculando reporte de preventistas:', error)
      notifyError('Error al calcular reporte de preventistas: ' + error.message)
      setReportePreventistas([])
      setReporteInicializado(true)
    } finally {
      setLoadingReporte(false)
    }
  }

  useEffect(() => { calcularMetricas() }, [])
  return {
    metricas,
    loading,
    loadingReporte,
    reportePreventistas,
    reporteInicializado,
    calcularReportePreventistas,
    refetch: calcularMetricas,
    filtroPeriodo,
    cambiarPeriodo
  }
}

export function useBackup() {
  const [exportando, setExportando] = useState(false)

  const exportarDatos = async (tipo = 'completo') => {
    setExportando(true)
    try {
      const backup = { fecha: new Date().toISOString(), tipo }
      if (tipo === 'completo' || tipo === 'clientes') { const { data } = await supabase.from('clientes').select('*'); backup.clientes = data }
      if (tipo === 'completo' || tipo === 'productos') { const { data } = await supabase.from('productos').select('*'); backup.productos = data }
      if (tipo === 'completo' || tipo === 'pedidos') { const { data } = await supabase.from('pedidos').select(`*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))`); backup.pedidos = data }
      return backup
    } finally { setExportando(false) }
  }

  const descargarJSON = async (tipo = 'completo') => {
    const datos = await exportarDatos(tipo)
    const blob = new Blob([JSON.stringify(datos, null, 2)], { type: 'application/json' })
    const url = URL.createObjectURL(blob); const a = document.createElement('a'); a.href = url
    a.download = `backup_${tipo}_${new Date().toISOString().split('T')[0]}.json`; a.click(); URL.revokeObjectURL(url)
  }

  const exportarPedidosExcel = async (pedidos) => {
    setExportando(true)
    try {
      // Mapeo de estados para mejor legibilidad
      const estadoLabels = {
        pendiente: 'Pendiente',
        en_preparacion: 'En Preparación',
        asignado: 'En Camino',
        entregado: 'Entregado'
      }
      const estadoPagoLabels = {
        pendiente: 'Pendiente',
        parcial: 'Parcial',
        pagado: 'Pagado'
      }
      const formaPagoLabels = {
        efectivo: 'Efectivo',
        transferencia: 'Transferencia',
        cheque: 'Cheque',
        cuenta_corriente: 'Cuenta Corriente',
        tarjeta: 'Tarjeta'
      }

      // Hoja principal de pedidos
      const datosPedidos = pedidos.map(p => ({
        'ID Pedido': p.id,
        'Fecha': new Date(p.created_at).toLocaleDateString('es-AR'),
        'Hora': new Date(p.created_at).toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit' }),
        'Cliente': p.cliente?.nombre_fantasia || 'Sin cliente',
        'Teléfono': p.cliente?.telefono || '-',
        'Dirección': p.cliente?.direccion || '-',
        'Zona': p.cliente?.zona || '-',
        'Estado Pedido': estadoLabels[p.estado] || p.estado,
        'Estado Pago': estadoPagoLabels[p.estado_pago] || p.estado_pago || 'Pendiente',
        'Forma de Pago': formaPagoLabels[p.forma_pago] || p.forma_pago || 'Efectivo',
        'Transportista': p.transportista?.nombre || 'Sin asignar',
        'Preventista': p.usuario?.nombre || '-',
        'Productos': p.items?.map(i => `${i.producto?.nombre || 'Producto'} x${i.cantidad}`).join(', ') || '-',
        'Cantidad Items': p.items?.reduce((sum, i) => sum + i.cantidad, 0) || 0,
        'Total': p.total || 0,
        'Notas': p.notas || '-',
        'Fecha Entrega': p.fecha_entrega ? new Date(p.fecha_entrega).toLocaleDateString('es-AR') : '-'
      }))

      // Hoja de detalle de items
      const datosItems = []
      pedidos.forEach(p => {
        p.items?.forEach(item => {
          datosItems.push({
            'ID Pedido': p.id,
            'Fecha Pedido': new Date(p.created_at).toLocaleDateString('es-AR'),
            'Cliente': p.cliente?.nombre_fantasia || 'Sin cliente',
            'Producto': item.producto?.nombre || 'Producto sin nombre',
            'Código': item.producto?.codigo || '-',
            'Categoría': item.producto?.categoria || '-',
            'Cantidad': item.cantidad,
            'Precio Unitario': item.precio_unitario || 0,
            'Subtotal': item.subtotal || (item.cantidad * item.precio_unitario) || 0
          })
        })
      })

      // Hoja de resumen por estado
      const resumenEstados = [
        { 'Estado': 'Pendiente', 'Cantidad': pedidos.filter(p => p.estado === 'pendiente').length, 'Total': pedidos.filter(p => p.estado === 'pendiente').reduce((s, p) => s + (p.total || 0), 0) },
        { 'Estado': 'En Preparación', 'Cantidad': pedidos.filter(p => p.estado === 'en_preparacion').length, 'Total': pedidos.filter(p => p.estado === 'en_preparacion').reduce((s, p) => s + (p.total || 0), 0) },
        { 'Estado': 'En Camino', 'Cantidad': pedidos.filter(p => p.estado === 'asignado').length, 'Total': pedidos.filter(p => p.estado === 'asignado').reduce((s, p) => s + (p.total || 0), 0) },
        { 'Estado': 'Entregado', 'Cantidad': pedidos.filter(p => p.estado === 'entregado').length, 'Total': pedidos.filter(p => p.estado === 'entregado').reduce((s, p) => s + (p.total || 0), 0) },
        { 'Estado': 'TOTAL', 'Cantidad': pedidos.length, 'Total': pedidos.reduce((s, p) => s + (p.total || 0), 0) }
      ]

      // Hoja de resumen por estado de pago
      const resumenPagos = [
        { 'Estado Pago': 'Pendiente', 'Cantidad': pedidos.filter(p => p.estado_pago === 'pendiente' || !p.estado_pago).length, 'Total': pedidos.filter(p => p.estado_pago === 'pendiente' || !p.estado_pago).reduce((s, p) => s + (p.total || 0), 0) },
        { 'Estado Pago': 'Parcial', 'Cantidad': pedidos.filter(p => p.estado_pago === 'parcial').length, 'Total': pedidos.filter(p => p.estado_pago === 'parcial').reduce((s, p) => s + (p.total || 0), 0) },
        { 'Estado Pago': 'Pagado', 'Cantidad': pedidos.filter(p => p.estado_pago === 'pagado').length, 'Total': pedidos.filter(p => p.estado_pago === 'pagado').reduce((s, p) => s + (p.total || 0), 0) }
      ]

      // Crear workbook
      const wb = XLSX.utils.book_new()

      // Agregar hojas
      const wsPedidos = XLSX.utils.json_to_sheet(datosPedidos)
      const wsItems = XLSX.utils.json_to_sheet(datosItems)
      const wsResumenEstados = XLSX.utils.json_to_sheet(resumenEstados)
      const wsResumenPagos = XLSX.utils.json_to_sheet(resumenPagos)

      // Ajustar anchos de columna para la hoja de pedidos
      wsPedidos['!cols'] = [
        { wch: 10 }, // ID
        { wch: 12 }, // Fecha
        { wch: 8 },  // Hora
        { wch: 25 }, // Cliente
        { wch: 15 }, // Teléfono
        { wch: 35 }, // Dirección
        { wch: 12 }, // Zona
        { wch: 14 }, // Estado Pedido
        { wch: 12 }, // Estado Pago
        { wch: 16 }, // Forma Pago
        { wch: 20 }, // Transportista
        { wch: 20 }, // Preventista
        { wch: 50 }, // Productos
        { wch: 12 }, // Cantidad Items
        { wch: 12 }, // Total
        { wch: 30 }, // Notas
        { wch: 14 }  // Fecha Entrega
      ]

      XLSX.utils.book_append_sheet(wb, wsPedidos, 'Pedidos')
      XLSX.utils.book_append_sheet(wb, wsItems, 'Detalle Items')
      XLSX.utils.book_append_sheet(wb, wsResumenEstados, 'Resumen Estados')
      XLSX.utils.book_append_sheet(wb, wsResumenPagos, 'Resumen Pagos')

      // Generar archivo y descargar
      const fecha = new Date().toISOString().split('T')[0]
      XLSX.writeFile(wb, `pedidos_${fecha}.xlsx`)
    } finally {
      setExportando(false)
    }
  }
  return { exportando, exportarDatos, descargarJSON, exportarPedidosExcel }
}

export function usePagos() {
  const [pagos, setPagos] = useState([])
  const [loading, setLoading] = useState(false)

  const fetchPagosCliente = async (clienteId) => {
    setLoading(true)
    try {
      const { data, error } = await supabase
        .from('pagos')
        .select('*, usuario:perfiles(id, nombre)')
        .eq('cliente_id', clienteId)
        .order('created_at', { ascending: false })
      if (error) throw error
      setPagos(data || [])
      return data || []
    } catch (error) {
      console.error('Error fetching pagos:', error)
      notifyError('Error al cargar pagos: ' + error.message)
      return []
    } finally {
      setLoading(false)
    }
  }

  const registrarPago = async (pago) => {
    try {
      const { data, error } = await supabase.from('pagos').insert([{
        cliente_id: pago.clienteId,
        pedido_id: pago.pedidoId || null,
        monto: parseFloat(pago.monto),
        forma_pago: pago.formaPago || 'efectivo',
        referencia: pago.referencia || null,
        notas: pago.notas || null,
        usuario_id: pago.usuarioId || null
      }]).select('*, usuario:perfiles(id, nombre)').single()
      if (error) throw error
      setPagos(prev => [data, ...prev])
      return data
    } catch (error) {
      console.error('Error registrando pago:', error)
      notifyError('Error al registrar pago: ' + error.message)
      throw error
    }
  }

  const eliminarPago = async (pagoId) => {
    try {
      const { error } = await supabase.from('pagos').delete().eq('id', pagoId)
      if (error) throw error
      setPagos(prev => prev.filter(p => p.id !== pagoId))
    } catch (error) {
      console.error('Error eliminando pago:', error)
      notifyError('Error al eliminar pago: ' + error.message)
      throw error
    }
  }

  const obtenerResumenCuenta = async (clienteId) => {
    try {
      const { data, error } = await supabase.rpc('obtener_resumen_cuenta_cliente', { p_cliente_id: clienteId })
      if (error) {
        // Fallback: calculate manually if RPC doesn't exist
        console.warn('RPC no disponible, calculando manualmente:', error.message)
        const { data: cliente } = await supabase.from('clientes').select('*').eq('id', clienteId).single()
        const { data: pedidosCliente } = await supabase.from('pedidos').select('*').eq('cliente_id', clienteId)
        const { data: pagosCliente } = await supabase.from('pagos').select('*').eq('cliente_id', clienteId)

        const totalCompras = (pedidosCliente || []).reduce((s, p) => s + (p.total || 0), 0)
        const totalPagos = (pagosCliente || []).reduce((s, p) => s + (p.monto || 0), 0)

        return {
          saldo_actual: totalCompras - totalPagos,
          limite_credito: cliente?.limite_credito || 0,
          credito_disponible: (cliente?.limite_credito || 0) - (totalCompras - totalPagos),
          total_pedidos: (pedidosCliente || []).length,
          total_compras: totalCompras,
          total_pagos: totalPagos,
          pedidos_pendientes_pago: (pedidosCliente || []).filter(p => p.estado_pago !== 'pagado').length,
          ultimo_pedido: pedidosCliente?.length ? Math.max(...pedidosCliente.map(p => new Date(p.created_at))) : null,
          ultimo_pago: pagosCliente?.length ? Math.max(...pagosCliente.map(p => new Date(p.created_at))) : null
        }
      }
      return data
    } catch (error) {
      console.error('Error obteniendo resumen:', error)
      return null
    }
  }

  return { pagos, loading, fetchPagosCliente, registrarPago, eliminarPago, obtenerResumenCuenta }
}

export function useFichaCliente(clienteId) {
  const [pedidosCliente, setPedidosCliente] = useState([])
  const [estadisticas, setEstadisticas] = useState(null)
  const [loading, setLoading] = useState(false)

  const fetchDatosCliente = async () => {
    if (!clienteId) return
    setLoading(true)
    try {
      // Fetch orders with items
      const { data: pedidos, error: errorPedidos } = await supabase
        .from('pedidos')
        .select(`*, items:pedido_items(*, producto:productos(*))`)
        .eq('cliente_id', clienteId)
        .order('created_at', { ascending: false })
      if (errorPedidos) throw errorPedidos
      setPedidosCliente(pedidos || [])

      // Calculate statistics
      const pedidosData = pedidos || []
      const totalCompras = pedidosData.reduce((s, p) => s + (p.total || 0), 0)
      const pedidosPagados = pedidosData.filter(p => p.estado_pago === 'pagado')
      const pedidosPendientes = pedidosData.filter(p => p.estado_pago !== 'pagado')

      // Product frequency
      const productosFrecuencia = {}
      pedidosData.forEach(p => {
        p.items?.forEach(item => {
          const nombre = item.producto?.nombre || 'Desconocido'
          if (!productosFrecuencia[nombre]) productosFrecuencia[nombre] = { nombre, cantidad: 0, veces: 0 }
          productosFrecuencia[nombre].cantidad += item.cantidad
          productosFrecuencia[nombre].veces += 1
        })
      })
      const productosFavoritos = Object.values(productosFrecuencia).sort((a, b) => b.cantidad - a.cantidad).slice(0, 5)

      // Days since last order
      const ultimoPedido = pedidosData[0]?.created_at
      const diasDesdeUltimoP = ultimoPedido
        ? Math.floor((new Date() - new Date(ultimoPedido)) / (1000 * 60 * 60 * 24))
        : null

      // Average ticket
      const ticketPromedio = pedidosData.length > 0 ? totalCompras / pedidosData.length : 0

      // Purchase frequency (orders per month)
      let frecuenciaCompra = 0
      if (pedidosData.length > 1) {
        const primerPedido = new Date(pedidosData[pedidosData.length - 1].created_at)
        const ultimoPedidoDate = new Date(pedidosData[0].created_at)
        const meses = Math.max(1, (ultimoPedidoDate - primerPedido) / (1000 * 60 * 60 * 24 * 30))
        frecuenciaCompra = pedidosData.length / meses
      }

      setEstadisticas({
        totalPedidos: pedidosData.length,
        totalCompras,
        pedidosPagados: pedidosPagados.length,
        montoPagado: pedidosPagados.reduce((s, p) => s + (p.total || 0), 0),
        pedidosPendientes: pedidosPendientes.length,
        montoPendiente: pedidosPendientes.reduce((s, p) => s + (p.total || 0), 0),
        ticketPromedio,
        frecuenciaCompra,
        diasDesdeUltimoPedido: diasDesdeUltimoP,
        productosFavoritos
      })
    } catch (error) {
      console.error('Error fetching datos cliente:', error)
      notifyError('Error al cargar datos del cliente: ' + error.message)
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    if (clienteId) fetchDatosCliente()
  }, [clienteId])

  return { pedidosCliente, estadisticas, loading, refetch: fetchDatosCliente }
}

export function useReportesFinancieros() {
  const [loading, setLoading] = useState(false)

  const generarReporteCuentasPorCobrar = async () => {
    setLoading(true)
    try {
      const { data: clientes, error: errorClientes } = await supabase
        .from('clientes')
        .select('*')
        .order('nombre_fantasia')
      if (errorClientes) throw errorClientes

      const { data: pedidos, error: errorPedidos } = await supabase
        .from('pedidos')
        .select('*')
        .neq('estado_pago', 'pagado')
      if (errorPedidos) throw errorPedidos

      const { data: pagos, error: errorPagos } = await supabase
        .from('pagos')
        .select('*')
      if (errorPagos && !errorPagos.message.includes('does not exist')) throw errorPagos

      const hoy = new Date()
      const reporte = (clientes || []).map(cliente => {
        const pedidosCliente = (pedidos || []).filter(p => p.cliente_id === cliente.id)
        const pagosCliente = (pagos || []).filter(p => p.cliente_id === cliente.id)

        const totalDeuda = pedidosCliente.reduce((s, p) => s + (p.total || 0), 0)
        const totalPagado = pagosCliente.reduce((s, p) => s + (p.monto || 0), 0)
        const saldoPendiente = totalDeuda - totalPagado

        // Aging analysis
        let corriente = 0, vencido30 = 0, vencido60 = 0, vencido90 = 0
        pedidosCliente.forEach(p => {
          const fechaPedido = new Date(p.created_at)
          const diasCredito = cliente.dias_credito || 30
          const fechaVencimiento = new Date(fechaPedido)
          fechaVencimiento.setDate(fechaVencimiento.getDate() + diasCredito)
          const diasVencido = Math.floor((hoy - fechaVencimiento) / (1000 * 60 * 60 * 24))

          if (diasVencido <= 0) corriente += p.total || 0
          else if (diasVencido <= 30) vencido30 += p.total || 0
          else if (diasVencido <= 60) vencido60 += p.total || 0
          else vencido90 += p.total || 0
        })

        return {
          cliente,
          totalDeuda,
          totalPagado,
          saldoPendiente,
          limiteCredito: cliente.limite_credito || 0,
          creditoDisponible: (cliente.limite_credito || 0) - saldoPendiente,
          aging: { corriente, vencido30, vencido60, vencido90 },
          pedidosPendientes: pedidosCliente.length
        }
      }).filter(r => r.saldoPendiente > 0).sort((a, b) => b.saldoPendiente - a.saldoPendiente)

      return reporte
    } catch (error) {
      console.error('Error generando reporte:', error)
      notifyError('Error al generar reporte: ' + error.message)
      return []
    } finally {
      setLoading(false)
    }
  }

  const generarReporteRentabilidad = async (fechaDesde = null, fechaHasta = null) => {
    setLoading(true)
    try {
      let query = supabase.from('pedidos').select(`*, items:pedido_items(*, producto:productos(*))`)
      if (fechaDesde) query = query.gte('created_at', `${fechaDesde}T00:00:00`)
      if (fechaHasta) query = query.lte('created_at', `${fechaHasta}T23:59:59`)

      const { data: pedidos, error } = await query
      if (error) throw error

      // Por producto
      const productoStats = {}
      ;(pedidos || []).forEach(p => {
        p.items?.forEach(item => {
          const prod = item.producto
          if (!prod) return
          const id = prod.id
          if (!productoStats[id]) {
            productoStats[id] = {
              id,
              nombre: prod.nombre,
              codigo: prod.codigo,
              cantidadVendida: 0,
              ingresos: 0,
              costos: 0,
              margen: 0
            }
          }
          productoStats[id].cantidadVendida += item.cantidad
          productoStats[id].ingresos += item.subtotal || (item.cantidad * item.precio_unitario)
          const costoUnitario = prod.costo_con_iva || prod.costo_sin_iva || 0
          productoStats[id].costos += costoUnitario * item.cantidad
        })
      })

      const reporteProductos = Object.values(productoStats).map(p => ({
        ...p,
        margen: p.ingresos - p.costos,
        margenPorcentaje: p.ingresos > 0 ? ((p.ingresos - p.costos) / p.ingresos * 100) : 0
      })).sort((a, b) => b.margen - a.margen)

      // Totals
      const totales = {
        ingresosTotales: reporteProductos.reduce((s, p) => s + p.ingresos, 0),
        costosTotales: reporteProductos.reduce((s, p) => s + p.costos, 0),
        margenTotal: reporteProductos.reduce((s, p) => s + p.margen, 0),
        cantidadPedidos: (pedidos || []).length
      }
      totales.margenPorcentaje = totales.ingresosTotales > 0
        ? (totales.margenTotal / totales.ingresosTotales * 100)
        : 0

      return { productos: reporteProductos, totales }
    } catch (error) {
      console.error('Error generando reporte rentabilidad:', error)
      notifyError('Error al generar reporte: ' + error.message)
      return { productos: [], totales: {} }
    } finally {
      setLoading(false)
    }
  }

  const generarReporteVentasPorCliente = async (fechaDesde = null, fechaHasta = null) => {
    setLoading(true)
    try {
      let query = supabase.from('pedidos').select(`*, cliente:clientes(*)`)
      if (fechaDesde) query = query.gte('created_at', `${fechaDesde}T00:00:00`)
      if (fechaHasta) query = query.lte('created_at', `${fechaHasta}T23:59:59`)

      const { data: pedidos, error } = await query
      if (error) throw error

      const clienteStats = {}
      ;(pedidos || []).forEach(p => {
        const clienteId = p.cliente_id
        if (!clienteStats[clienteId]) {
          clienteStats[clienteId] = {
            cliente: p.cliente,
            cantidadPedidos: 0,
            totalVentas: 0,
            pedidosPagados: 0,
            pedidosPendientes: 0
          }
        }
        clienteStats[clienteId].cantidadPedidos += 1
        clienteStats[clienteId].totalVentas += p.total || 0
        if (p.estado_pago === 'pagado') clienteStats[clienteId].pedidosPagados += 1
        else clienteStats[clienteId].pedidosPendientes += 1
      })

      return Object.values(clienteStats).sort((a, b) => b.totalVentas - a.totalVentas)
    } catch (error) {
      console.error('Error generando reporte:', error)
      return []
    } finally {
      setLoading(false)
    }
  }

  const generarReporteVentasPorZona = async (fechaDesde = null, fechaHasta = null) => {
    setLoading(true)
    try {
      let query = supabase.from('pedidos').select(`*, cliente:clientes(*)`)
      if (fechaDesde) query = query.gte('created_at', `${fechaDesde}T00:00:00`)
      if (fechaHasta) query = query.lte('created_at', `${fechaHasta}T23:59:59`)

      const { data: pedidos, error } = await query
      if (error) throw error

      const zonaStats = {}
      ;(pedidos || []).forEach(p => {
        const zona = p.cliente?.zona || 'Sin zona'
        if (!zonaStats[zona]) {
          zonaStats[zona] = {
            zona,
            cantidadPedidos: 0,
            totalVentas: 0,
            clientes: new Set()
          }
        }
        zonaStats[zona].cantidadPedidos += 1
        zonaStats[zona].totalVentas += p.total || 0
        zonaStats[zona].clientes.add(p.cliente_id)
      })

      return Object.values(zonaStats).map(z => ({
        ...z,
        cantidadClientes: z.clientes.size,
        ticketPromedio: z.cantidadPedidos > 0 ? z.totalVentas / z.cantidadPedidos : 0
      })).sort((a, b) => b.totalVentas - a.totalVentas)
    } catch (error) {
      console.error('Error generando reporte:', error)
      return []
    } finally {
      setLoading(false)
    }
  }

  return {
    loading,
    generarReporteCuentasPorCobrar,
    generarReporteRentabilidad,
    generarReporteVentasPorCliente,
    generarReporteVentasPorZona
  }
}

import { useState, useEffect, createContext, useContext } from 'react'
import { supabase } from '../lib/supabase'

const AuthContext = createContext({})

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
    const { data, error } = await supabase.from('clientes').select('*').order('nombre_fantasia')
    if (error) console.error('Error fetching clientes:', error)
    setClientes(data || []); setLoading(false)
  }
  useEffect(() => { fetchClientes() }, [])

  const agregarCliente = async (cliente) => {
    const { data, error } = await supabase.from('clientes').insert([{ nombre: cliente.nombre, nombre_fantasia: cliente.nombreFantasia, direccion: cliente.direccion, telefono: cliente.telefono || null, zona: cliente.zona || null }]).select().single()
    if (error) throw error
    setClientes(prev => [...prev, data].sort((a, b) => a.nombre_fantasia.localeCompare(b.nombre_fantasia))); return data
  }
  const actualizarCliente = async (id, cliente) => {
    const { data, error } = await supabase.from('clientes').update({ nombre: cliente.nombre, nombre_fantasia: cliente.nombreFantasia, direccion: cliente.direccion, telefono: cliente.telefono || null, zona: cliente.zona || null }).eq('id', id).select().single()
    if (error) throw error; setClientes(prev => prev.map(c => c.id === id ? data : c)); return data
  }
  const eliminarCliente = async (id) => { const { error } = await supabase.from('clientes').delete().eq('id', id); if (error) throw error; setClientes(prev => prev.filter(c => c.id !== id)) }
  return { clientes, loading, agregarCliente, actualizarCliente, eliminarCliente, refetch: fetchClientes }
}

export function useProductos() {
  const [productos, setProductos] = useState([])
  const [loading, setLoading] = useState(true)

  const fetchProductos = async () => { setLoading(true); const { data, error } = await supabase.from('productos').select('*').order('nombre'); if (error) console.error('Error fetching productos:', error); setProductos(data || []); setLoading(false) }
  useEffect(() => { fetchProductos() }, [])

  const agregarProducto = async (producto) => { const { data, error } = await supabase.from('productos').insert([{ nombre: producto.nombre, precio: producto.precio, stock: producto.stock, categoria: producto.categoria || null }]).select().single(); if (error) throw error; setProductos(prev => [...prev, data].sort((a, b) => a.nombre.localeCompare(b.nombre))); return data }
  const actualizarProducto = async (id, producto) => { const { data, error } = await supabase.from('productos').update({ nombre: producto.nombre, precio: producto.precio, stock: producto.stock, categoria: producto.categoria || null }).eq('id', id).select().single(); if (error) throw error; setProductos(prev => prev.map(p => p.id === id ? data : p)); return data }
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
    for (const item of items) {
      const producto = productos.find(p => p.id === item.productoId)
      if (!producto) continue
      const nuevoStock = producto.stock - item.cantidad
      const { error } = await supabase.from('productos').update({ stock: nuevoStock }).eq('id', item.productoId)
      if (error) throw error
      setProductos(prev => prev.map(p => p.id === item.productoId ? { ...p, stock: nuevoStock } : p))
    }
  }

  const restaurarStock = async (items) => {
    for (const item of items) {
      const producto = productos.find(p => p.id === item.producto_id || p.id === item.productoId)
      if (!producto) continue
      const nuevoStock = producto.stock + item.cantidad
      const { error } = await supabase.from('productos').update({ stock: nuevoStock }).eq('id', producto.id)
      if (error) throw error
      setProductos(prev => prev.map(p => p.id === producto.id ? { ...p, stock: nuevoStock } : p))
    }
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
    } catch (err) { console.error('Error inesperado en fetchPedidos:', err); setPedidos([]) }
    setLoading(false)
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
    } catch (err) {
      console.error('Error fetching historial:', err)
      return []
    }
  }

  const pedidosFiltrados = () => pedidos.filter(p => {
    if (filtros.estado !== 'todos' && p.estado !== filtros.estado) return false
    if (filtros.fechaDesde) { const fp = new Date(p.created_at).setHours(0,0,0,0); const fd = new Date(filtros.fechaDesde).setHours(0,0,0,0); if (fp < fd) return false }
    if (filtros.fechaHasta) { const fp = new Date(p.created_at).setHours(23,59,59,999); const fh = new Date(filtros.fechaHasta).setHours(23,59,59,999); if (fp > fh) return false }
    return true
  })

  const crearPedido = async (clienteId, items, total, usuarioId, descontarStockFn, notas = '', formaPago = 'efectivo', estadoPago = 'pendiente') => {
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

  const cambiarEstado = async (id, nuevoEstado) => {
    const updateData = { estado: nuevoEstado }
    if (nuevoEstado === 'entregado') updateData.fecha_entrega = new Date().toISOString(); else updateData.fecha_entrega = null
    const { error } = await supabase.from('pedidos').update(updateData).eq('id', id); if (error) throw error
    setPedidos(prev => prev.map(p => p.id === id ? { ...p, ...updateData } : p))
  }

  const asignarTransportista = async (pedidoId, transportistaId) => {
    const { error } = await supabase.from('pedidos').update({ transportista_id: transportistaId || null, estado: transportistaId ? 'asignado' : 'pendiente' }).eq('id', pedidoId)
    if (error) throw error; await fetchPedidos()
  }

  const eliminarPedido = async (id, restaurarStockFn) => {
    const pedido = pedidos.find(p => p.id === id)
    if (pedido?.stock_descontado && pedido?.items && restaurarStockFn) await restaurarStockFn(pedido.items)
    await supabase.from('pedido_items').delete().eq('pedido_id', id)
    const { error } = await supabase.from('pedidos').delete().eq('id', id); if (error) throw error
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

  const fetchUsuarios = async () => { setLoading(true); const { data, error } = await supabase.from('perfiles').select('*').order('nombre'); if (error) console.error('Error fetching usuarios:', error); setUsuarios(data || []); setTransportistas((data || []).filter(u => u.rol === 'transportista' && u.activo)); setLoading(false) }
  useEffect(() => { fetchUsuarios() }, [])

  const actualizarUsuario = async (id, datos) => {
    const { data, error } = await supabase.from('perfiles').update({ nombre: datos.nombre, rol: datos.rol, activo: datos.activo }).eq('id', id).select().single()
    if (error) throw error; setUsuarios(prev => prev.map(u => u.id === id ? data : u))
    setTransportistas(prev => { const updated = prev.filter(t => t.id !== id); if (data.rol === 'transportista' && data.activo) return [...updated, data].sort((a, b) => a.nombre.localeCompare(b.nombre)); return updated })
    return data
  }
  return { usuarios, transportistas, loading, actualizarUsuario, refetch: fetchUsuarios }
}

export function useDashboard() {
  const [metricas, setMetricas] = useState({ ventasHoy: 0, ventasSemana: 0, ventasMes: 0, pedidosHoy: 0, pedidosSemana: 0, pedidosMes: 0, productosMasVendidos: [], clientesMasActivos: [], pedidosPorEstado: { pendiente: 0, asignado: 0, entregado: 0 }, ventasPorDia: [] })
  const [loading, setLoading] = useState(true)
  const [reportePreventistas, setReportePreventistas] = useState([])

  const calcularMetricas = async () => {
    setLoading(true)
    try {
      const inicioMes = new Date(); inicioMes.setDate(1); inicioMes.setHours(0,0,0,0)
      const { data: pedidos } = await supabase.from('pedidos').select(`*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))`).gte('created_at', inicioMes.toISOString())
      if (!pedidos) { setLoading(false); return }

      const hoy = new Date(); hoy.setHours(0,0,0,0)
      const hace7Dias = new Date(); hace7Dias.setDate(hace7Dias.getDate() - 7); hace7Dias.setHours(0,0,0,0)
      const pedidosHoy = pedidos.filter(p => new Date(p.created_at) >= hoy)
      const pedidosSemana = pedidos.filter(p => new Date(p.created_at) >= hace7Dias)

      const productosVendidos = {}
      pedidos.forEach(p => p.items?.forEach(i => { const id = i.producto_id; if (!productosVendidos[id]) productosVendidos[id] = { id, nombre: i.producto?.nombre || 'N/A', cantidad: 0 }; productosVendidos[id].cantidad += i.cantidad }))
      const topProductos = Object.values(productosVendidos).sort((a, b) => b.cantidad - a.cantidad).slice(0, 5)

      const clientesActivos = {}
      pedidos.forEach(p => { const id = p.cliente_id; if (!clientesActivos[id]) clientesActivos[id] = { id, nombre: p.cliente?.nombre_fantasia || 'N/A', total: 0, pedidos: 0 }; clientesActivos[id].total += p.total || 0; clientesActivos[id].pedidos += 1 })
      const topClientes = Object.values(clientesActivos).sort((a, b) => b.total - a.total).slice(0, 5)

      const ventasPorDia = []
      for (let i = 6; i >= 0; i--) {
        const fecha = new Date(); fecha.setDate(fecha.getDate() - i); fecha.setHours(0,0,0,0)
        const finDia = new Date(fecha); finDia.setHours(23,59,59,999)
        const pedidosDia = pedidos.filter(p => { const f = new Date(p.created_at); return f >= fecha && f <= finDia })
        ventasPorDia.push({ dia: fecha.toLocaleDateString('es-AR', { weekday: 'short' }), ventas: pedidosDia.reduce((s, p) => s + (p.total || 0), 0), pedidos: pedidosDia.length })
      }

      setMetricas({
        ventasHoy: pedidosHoy.reduce((s, p) => s + (p.total || 0), 0), ventasSemana: pedidosSemana.reduce((s, p) => s + (p.total || 0), 0), ventasMes: pedidos.reduce((s, p) => s + (p.total || 0), 0),
        pedidosHoy: pedidosHoy.length, pedidosSemana: pedidosSemana.length, pedidosMes: pedidos.length,
        productosMasVendidos: topProductos, clientesMasActivos: topClientes,
        pedidosPorEstado: { pendiente: pedidos.filter(p => p.estado === 'pendiente').length, asignado: pedidos.filter(p => p.estado === 'asignado').length, entregado: pedidos.filter(p => p.estado === 'entregado').length },
        ventasPorDia
      })
    } catch (err) { console.error('Error calculando métricas:', err) }
    setLoading(false)
  }
  const calcularReportePreventistas = async (fechaDesde = null, fechaHasta = null) => {
    setLoading(true)
    try {
      let query = supabase
        .from('pedidos')
        .select(`*, usuario:perfiles(id, nombre, email), items:pedido_items(*)`)

      if (fechaDesde) query = query.gte('created_at', new Date(fechaDesde).toISOString())
      if (fechaHasta) {
        const hasta = new Date(fechaHasta)
        hasta.setHours(23, 59, 59, 999)
        query = query.lte('created_at', hasta.toISOString())
      }

      const { data: pedidos } = await query

      if (!pedidos) {
        setReportePreventistas([])
        setLoading(false)
        return
      }

      const reportePorPreventista = {}

      pedidos.forEach(pedido => {
        const usuarioId = pedido.usuario_id
        const usuarioNombre = pedido.usuario?.nombre || 'Usuario desconocido'

        if (!reportePorPreventista[usuarioId]) {
          reportePorPreventista[usuarioId] = {
            id: usuarioId,
            nombre: usuarioNombre,
            email: pedido.usuario?.email || 'N/A',
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
    } catch (err) {
      console.error('Error calculando reporte de preventistas:', err)
      setReportePreventistas([])
    }
    setLoading(false)
  }

  useEffect(() => { calcularMetricas() }, [])
  return {
    metricas,
    loading,
    reportePreventistas,
    calcularReportePreventistas,
    refetch: calcularMetricas
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

  const exportarPedidosCSV = async (pedidos) => {
    setExportando(true)
    try {
      const headers = ['ID', 'Fecha', 'Cliente', 'Dirección', 'Estado', 'Total', 'Productos']
      const rows = pedidos.map(p => [p.id, new Date(p.created_at).toLocaleDateString('es-AR'), p.cliente?.nombre_fantasia || '', p.cliente?.direccion || '', p.estado, p.total, p.items?.map(i => `${i.producto?.nombre} x${i.cantidad}`).join('; ') || ''])
      const csv = [headers.join(','), ...rows.map(r => r.map(c => `"${c}"`).join(','))].join('\n')
      const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' }); const url = URL.createObjectURL(blob)
      const a = document.createElement('a'); a.href = url; a.download = `pedidos_${new Date().toISOString().split('T')[0]}.csv`; a.click(); URL.revokeObjectURL(url)
    } finally { setExportando(false) }
  }
  return { exportando, exportarDatos, descargarJSON, exportarPedidosCSV }
}

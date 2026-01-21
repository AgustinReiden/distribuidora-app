import { useState, useEffect } from 'react'
import { supabase, notifyError } from './base'

export function useDashboard(usuarioFiltro = null) {
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
  const [filtroPeriodo, setFiltroPeriodo] = useState('mes')
  const [fechaDesde, setFechaDesde] = useState(null)
  const [fechaHasta, setFechaHasta] = useState(null)

  const calcularMetricas = async (periodo = filtroPeriodo, fDesde = fechaDesde, fHasta = fechaHasta) => {
    setLoading(true)
    try {
      let query = supabase
        .from('pedidos')
        .select(`*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))`)

      if (usuarioFiltro) {
        query = query.eq('usuario_id', usuarioFiltro)
      }

      const { data: todosPedidos, error: errorTodos } = await query.order('created_at', { ascending: false })

      if (errorTodos) throw errorTodos
      if (!todosPedidos) { setLoading(false); return }

      const hoy = new Date()
      const hoyStr = hoy.toISOString().split('T')[0]
      let fechaInicioStr = null

      switch (periodo) {
        case 'hoy':
          fechaInicioStr = hoyStr
          break
        case 'semana': {
          const hace7Dias = new Date()
          hace7Dias.setDate(hace7Dias.getDate() - 7)
          fechaInicioStr = hace7Dias.toISOString().split('T')[0]
          break
        }
        case 'mes': {
          const inicioMes = new Date(hoy.getFullYear(), hoy.getMonth(), 1)
          fechaInicioStr = inicioMes.toISOString().split('T')[0]
          break
        }
        case 'anio': {
          const inicioAnio = new Date(hoy.getFullYear(), 0, 1)
          fechaInicioStr = inicioAnio.toISOString().split('T')[0]
          break
        }
        case 'personalizado':
          fechaInicioStr = fDesde || null
          break
        case 'historico':
        default:
          fechaInicioStr = null
          break
      }

      let pedidosFiltrados = todosPedidos
      if (fechaInicioStr) {
        pedidosFiltrados = todosPedidos.filter(p => p.created_at?.split('T')[0] >= fechaInicioStr)
      }
      if (periodo === 'personalizado' && fHasta) {
        pedidosFiltrados = pedidosFiltrados.filter(p => p.created_at?.split('T')[0] <= fHasta)
      }

      const productosVendidos = {}
      pedidosFiltrados.forEach(p => p.items?.forEach(i => {
        const id = i.producto_id
        if (!productosVendidos[id]) productosVendidos[id] = { id, nombre: i.producto?.nombre || 'N/A', cantidad: 0 }
        productosVendidos[id].cantidad += i.cantidad
      }))
      const topProductos = Object.values(productosVendidos).sort((a, b) => b.cantidad - a.cantidad).slice(0, 5)

      const clientesActivos = {}
      pedidosFiltrados.forEach(p => {
        const id = p.cliente_id
        if (!clientesActivos[id]) clientesActivos[id] = { id, nombre: p.cliente?.nombre_fantasia || 'N/A', total: 0, pedidos: 0 }
        clientesActivos[id].total += p.total || 0
        clientesActivos[id].pedidos += 1
      })
      const topClientes = Object.values(clientesActivos).sort((a, b) => b.total - a.total).slice(0, 5)

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

  const calcularReportePreventistas = async (fechaDesdeParam = null, fechaHastaParam = null) => {
    setLoadingReporte(true)
    try {
      let query = supabase.from('pedidos').select(`*, items:pedido_items(*)`)

      if (fechaDesdeParam) {
        query = query.gte('created_at', `${fechaDesdeParam}T00:00:00`)
      }
      if (fechaHastaParam) {
        query = query.lte('created_at', `${fechaHastaParam}T23:59:59`)
      }

      const { data: pedidos, error } = await query
      if (error) throw error

      if (!pedidos || pedidos.length === 0) {
        setReportePreventistas([])
        setReporteInicializado(true)
        return
      }

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

import { useState, useEffect } from 'react'
import { supabase, notifyError } from './base'

export function useFichaCliente(clienteId) {
  const [pedidosCliente, setPedidosCliente] = useState([])
  const [estadisticas, setEstadisticas] = useState(null)
  const [loading, setLoading] = useState(false)

  const fetchDatosCliente = async () => {
    if (!clienteId) return
    setLoading(true)
    try {
      const { data: pedidos, error: errorPedidos } = await supabase
        .from('pedidos')
        .select(`*, items:pedido_items(*, producto:productos(*))`)
        .eq('cliente_id', clienteId)
        .order('created_at', { ascending: false })
      if (errorPedidos) throw errorPedidos
      setPedidosCliente(pedidos || [])

      const pedidosData = pedidos || []
      const totalCompras = pedidosData.reduce((s, p) => s + (p.total || 0), 0)
      const pedidosPagados = pedidosData.filter(p => p.estado_pago === 'pagado')
      const pedidosPendientes = pedidosData.filter(p => p.estado_pago !== 'pagado')

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

      const ultimoPedido = pedidosData[0]?.created_at
      const diasDesdeUltimoP = ultimoPedido
        ? Math.floor((new Date() - new Date(ultimoPedido)) / (1000 * 60 * 60 * 24))
        : null

      const ticketPromedio = pedidosData.length > 0 ? totalCompras / pedidosData.length : 0

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

import { useState, useEffect } from 'react'
import { supabase, notifyError } from './base'
import type {
  PedidoClienteWithItems,
  EstadisticasCliente,
  ProductoFavorito,
  UseFichaClienteReturn,
  PedidoDB,
  ProductoDB
} from '../../types'

interface PedidoWithItems {
  id: string;
  cliente_id: string;
  estado: string;
  estado_pago?: string;
  total: number;
  monto_pagado?: number;
  created_at?: string;
  items?: Array<{
    cantidad: number;
    producto?: ProductoDB | null;
  }>;
}

interface ProductosFrecuenciaMap {
  [key: string]: ProductoFavorito;
}

export function useFichaCliente(clienteId: string | null | undefined): UseFichaClienteReturn {
  const [pedidosCliente, setPedidosCliente] = useState<PedidoClienteWithItems[]>([])
  const [estadisticas, setEstadisticas] = useState<EstadisticasCliente | null>(null)
  const [loading, setLoading] = useState<boolean>(false)

  const fetchDatosCliente = async (): Promise<void> => {
    if (!clienteId) return
    setLoading(true)
    try {
      const { data: pedidos, error: errorPedidos } = await supabase
        .from('pedidos')
        .select(`*, items:pedido_items(*, producto:productos(*))`)
        .eq('cliente_id', clienteId)
        .order('created_at', { ascending: false })
      if (errorPedidos) throw errorPedidos

      const pedidosTyped = (pedidos || []) as PedidoWithItems[]
      setPedidosCliente(pedidosTyped as unknown as PedidoClienteWithItems[])

      const pedidosData = pedidosTyped
      const totalCompras = pedidosData.reduce((s, p) => s + (p.total || 0), 0)
      const pedidosPagados = pedidosData.filter(p => p.estado_pago === 'pagado')
      const pedidosPendientes = pedidosData.filter(p => p.estado_pago !== 'pagado')

      // Calcular montos considerando monto_pagado (pagos parciales y directos)
      const totalPagadoEnPedidos = pedidosData.reduce((s, p) => s + (p.monto_pagado || 0), 0)
      const totalPendienteReal = pedidosData.reduce((s, p) => s + ((p.total || 0) - (p.monto_pagado || 0)), 0)

      const productosFrecuencia: ProductosFrecuenciaMap = {}
      pedidosData.forEach(p => {
        p.items?.forEach(item => {
          const nombre = item.producto?.nombre || 'Desconocido'
          if (!productosFrecuencia[nombre]) productosFrecuencia[nombre] = { nombre, cantidad: 0, veces: 0 }
          productosFrecuencia[nombre].cantidad += item.cantidad
          productosFrecuencia[nombre].veces += 1
        })
      })
      const productosFavoritos: ProductoFavorito[] = Object.values(productosFrecuencia)
        .sort((a, b) => b.cantidad - a.cantidad)
        .slice(0, 5)

      const ultimoPedido = pedidosData[0]?.created_at
      const diasDesdeUltimoP = ultimoPedido
        ? Math.floor((new Date().getTime() - new Date(ultimoPedido).getTime()) / (1000 * 60 * 60 * 24))
        : null

      const ticketPromedio = pedidosData.length > 0 ? totalCompras / pedidosData.length : 0

      let frecuenciaCompra = 0
      if (pedidosData.length > 1) {
        const primerPedido = new Date(pedidosData[pedidosData.length - 1].created_at || 0)
        const ultimoPedidoDate = new Date(pedidosData[0].created_at || 0)
        const meses = Math.max(1, (ultimoPedidoDate.getTime() - primerPedido.getTime()) / (1000 * 60 * 60 * 24 * 30))
        frecuenciaCompra = pedidosData.length / meses
      }

      setEstadisticas({
        totalPedidos: pedidosData.length,
        totalCompras,
        pedidosPagados: pedidosPagados.length,
        montoPagado: totalPagadoEnPedidos,
        pedidosPendientes: pedidosPendientes.length,
        montoPendiente: totalPendienteReal,
        ticketPromedio,
        frecuenciaCompra,
        diasDesdeUltimoPedido: diasDesdeUltimoP,
        productosFavoritos
      })
    } catch (error) {
      notifyError('Error al cargar datos del cliente: ' + (error as Error).message)
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    if (clienteId) fetchDatosCliente()
  }, [clienteId])

  return { pedidosCliente, estadisticas, loading, refetch: fetchDatosCliente }
}

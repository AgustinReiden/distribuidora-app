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
      // Query ligera: todos los pedidos del cliente (sólo columnas necesarias para stats)
      const { data: todosLiviano, error: errorLiv } = await supabase
        .from('pedidos')
        .select('id, total, estado, estado_pago, created_at')
        .eq('cliente_id', clienteId)
        .order('created_at', { ascending: false })
      if (errorLiv) throw errorLiv

      // Query pesada: últimos 50 pedidos con items (para UI + productos favoritos)
      const { data: pedidos, error: errorPedidos } = await supabase
        .from('pedidos')
        .select(`*, items:pedido_items(*, producto:productos(*))`)
        .eq('cliente_id', clienteId)
        .order('created_at', { ascending: false })
        .limit(50)
      if (errorPedidos) throw errorPedidos

      const pedidosTyped = (pedidos || []) as PedidoWithItems[]
      setPedidosCliente(pedidosTyped as unknown as PedidoClienteWithItems[])

      const pedidosLivianos = (todosLiviano || []) as Array<Pick<PedidoDB, 'id' | 'total' | 'estado' | 'estado_pago' | 'created_at'>>
      // Cancelados se excluyen de toda la base de cálculo (no son "compras" reales).
      const pedidosActivos = pedidosLivianos.filter(p => p.estado !== 'cancelado')
      const totalCompras = pedidosActivos.reduce((s, p) => s + (p.total || 0), 0)
      const pedidosPagados = pedidosActivos.filter(p => p.estado_pago === 'pagado')
      // "Pendiente" = pedidos no entregados (lógica de entrega). La deuda se ve en "Saldo".
      const pedidosSinEntregar = pedidosActivos.filter(p => p.estado !== 'entregado')
      const montoSinEntregar = pedidosSinEntregar.reduce((s, p) => s + (p.total || 0), 0)

      // Fetch pagos from the pagos table (source of truth for payments)
      const { data: pagosCliente } = await supabase
        .from('pagos')
        .select('monto')
        .eq('cliente_id', clienteId)
      const totalPagosRegistrados = (pagosCliente || []).reduce((s: number, p: { monto: number }) => s + (p.monto || 0), 0)

      // Productos favoritos se calculan sobre los últimos 50 pedidos (limitación aceptada)
      const productosFrecuencia: ProductosFrecuenciaMap = {}
      pedidosTyped.forEach(p => {
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

      const ultimoPedido = pedidosActivos[0]?.created_at
      const diasDesdeUltimoP = ultimoPedido
        ? Math.floor((new Date().getTime() - new Date(ultimoPedido).getTime()) / (1000 * 60 * 60 * 24))
        : null

      const ticketPromedio = pedidosActivos.length > 0 ? totalCompras / pedidosActivos.length : 0

      let frecuenciaCompra = 0
      if (pedidosActivos.length > 1) {
        const primerPedido = new Date(pedidosActivos[pedidosActivos.length - 1].created_at || 0)
        const ultimoPedidoDate = new Date(pedidosActivos[0].created_at || 0)
        const meses = Math.max(1, (ultimoPedidoDate.getTime() - primerPedido.getTime()) / (1000 * 60 * 60 * 24 * 30))
        frecuenciaCompra = pedidosActivos.length / meses
      }

      setEstadisticas({
        totalPedidos: pedidosActivos.length,
        totalCompras,
        pedidosPagados: pedidosPagados.length,
        montoPagado: totalPagosRegistrados,
        pedidosPendientes: pedidosSinEntregar.length,
        montoPendiente: montoSinEntregar,
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
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [clienteId])

  return { pedidosCliente, estadisticas, loading, refetch: fetchDatosCliente }
}

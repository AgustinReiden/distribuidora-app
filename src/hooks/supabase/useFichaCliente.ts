import { errorDeSupabase } from '../../utils/errorDeSupabase'
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
import { traerTodo } from '../../utils/paginacion'
import { fechaLocalISO } from '../../utils/formatters'
import { calcularVentaCliente, calcularRitmoCompra } from '../../utils/ventaCliente'
import { PRODUCTO_COLUMNAS } from '../../lib/productoColumnas'
import { PEDIDO_ITEM_COLUMNAS } from '../../lib/pedidoItemColumnas'

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
      // Paginado aunque hoy el cliente más activo tenga ~117 pedidos: a su ritmo
      // cruza las 1.000 en unos 3 años, y cuando lo haga esto se convierte en el
      // bug de #521 —`totalCompras` saldría de los 1.000 pedidos más recientes y
      // `montoPagado` de 1.000 pagos cualesquiera, o sea dos universos
      // distintos—. La correctitud de hoy es coincidencia de volumen, no diseño.
      const todosLiviano = await traerTodo<Pick<PedidoDB, 'id' | 'cliente_id' | 'total' | 'estado' | 'estado_pago' | 'created_at' | 'canal' | 'fecha' | 'tipo_factura'>>(
        () => supabase
          .from('pedidos')
          .select('id, cliente_id, total, estado, estado_pago, created_at, canal, fecha, tipo_factura')
          .eq('cliente_id', clienteId)
          .order('created_at', { ascending: false })
          .order('id'),
        { etiqueta: 'pedidos del cliente' },
      )

      // Query pesada: últimos 50 pedidos con items (para UI + productos favoritos)
      const { data: pedidos, error: errorPedidos } = await supabase
        .from('pedidos')
        .select(`*, items:pedido_items(${PEDIDO_ITEM_COLUMNAS}, producto:productos(${PRODUCTO_COLUMNAS}))`)
        .eq('cliente_id', clienteId)
        .order('created_at', { ascending: false })
        .limit(50)
      if (errorPedidos) throw errorDeSupabase(errorPedidos, 'Sin conexión: no se pudo cargar los pedidos del cliente. Revisá la señal e intentá de nuevo.')

      const pedidosTyped = (pedidos || []) as PedidoWithItems[]
      setPedidosCliente(pedidosTyped as unknown as PedidoClienteWithItems[])

      const pedidosLivianos = (todosLiviano || []) as Array<Pick<PedidoDB, 'id' | 'cliente_id' | 'total' | 'estado' | 'estado_pago' | 'created_at' | 'canal' | 'fecha' | 'tipo_factura'>>
      // Todas las cifras de compra salen de `calcularVentaCliente` / `calcularRitmoCompra`
      // (utils/ventaCliente): la venta es entregado, sin canje, sin vale blanco (VB,
      // consumo interno, va aparte). Lo tomado y no entregado va como "pendiente de
      // entrega", igual que el "en curso" del Dashboard. La deuda se ve en "Saldo".
      const venta = calcularVentaCliente(pedidosLivianos)
      const totalCompras = venta.totalComprado

      // Fetch pagos from the pagos table (source of truth for payments)
      const pagosCliente = await traerTodo<{ monto: number }>(
        () => supabase
          .from('pagos')
          .select('monto')
          .eq('cliente_id', clienteId)
          .order('id'),
        { etiqueta: 'pagos del cliente' },
      )
      const totalPagosRegistrados = pagosCliente.reduce((s: number, p: { monto: number }) => s + (p.monto || 0), 0)

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

      const ticketPromedio = venta.cantidadCompras > 0 ? totalCompras / venta.cantidadCompras : 0

      // Días sin comprar y frecuencia: sólo ventas, por `pedidos.fecha` (día argentino).
      const { diasDesdeUltimaCompra, frecuenciaCompra } = calcularRitmoCompra(pedidosLivianos, fechaLocalISO())

      setEstadisticas({
        totalPedidos: venta.cantidadCompras,
        totalCompras,
        pedidosPagados: venta.pedidosPagados,
        montoPagado: totalPagosRegistrados,
        pedidosPendientes: venta.pedidosPendientesEntrega,
        montoPendiente: venta.pendienteEntrega,
        ticketPromedio,
        frecuenciaCompra,
        diasDesdeUltimoPedido: diasDesdeUltimaCompra,
        productosFavoritos,
        consumoInterno: venta.consumoInterno
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

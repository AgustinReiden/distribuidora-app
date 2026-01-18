import { useState } from 'react'
import { supabase, notifyError } from './base'

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
      notifyError('Error al eliminar pago: ' + error.message)
      throw error
    }
  }

  const obtenerResumenCuenta = async (clienteId) => {
    try {
      const { data, error } = await supabase.rpc('obtener_resumen_cuenta_cliente', { p_cliente_id: clienteId })
      if (error) {
        const { data: cliente } = await supabase.from('clientes').select('*').eq('id', clienteId).single()
        const { data: pedidosCliente } = await supabase.from('pedidos').select('*').eq('cliente_id', clienteId)
        const { data: pagosCliente } = await supabase.from('pagos').select('*').eq('cliente_id', clienteId)

        const totalCompras = (pedidosCliente || []).reduce((s, p) => s + (p.total || 0), 0)
        const totalPagadoEnPedidos = (pedidosCliente || []).reduce((s, p) => s + (p.monto_pagado || 0), 0)
        const totalPagosRegistrados = (pagosCliente || []).reduce((s, p) => s + (p.monto || 0), 0)
        const saldoActual = totalCompras - totalPagadoEnPedidos - totalPagosRegistrados

        // Obtener última fecha correctamente (Math.max no funciona con Date)
        const ultimoPedidoFecha = (pedidosCliente || []).reduce((max, p) => {
          const fecha = new Date(p.created_at)
          return fecha > max ? fecha : max
        }, new Date(0))

        const ultimoPagoFecha = (pagosCliente || []).reduce((max, p) => {
          const fecha = new Date(p.created_at)
          return fecha > max ? fecha : max
        }, new Date(0))

        return {
          saldo_actual: saldoActual,
          limite_credito: cliente?.limite_credito || 0,
          credito_disponible: (cliente?.limite_credito || 0) - saldoActual,
          total_pedidos: (pedidosCliente || []).length,
          total_compras: totalCompras,
          total_pagos: totalPagadoEnPedidos + totalPagosRegistrados,
          pedidos_pendientes_pago: (pedidosCliente || []).filter(p => p.estado_pago !== 'pagado').length,
          ultimo_pedido: pedidosCliente?.length ? ultimoPedidoFecha.toISOString() : null,
          ultimo_pago: pagosCliente?.length ? ultimoPagoFecha.toISOString() : null
        }
      }
      return data
    } catch {
      return null
    }
  }

  return { pagos, loading, fetchPagosCliente, registrarPago, eliminarPago, obtenerResumenCuenta }
}

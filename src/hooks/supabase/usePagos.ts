import { useState } from 'react'
import { supabase, notifyError } from './base'
import type {
  PagoDBWithUsuario,
  PagoFormInput,
  ResumenCuenta,
  UsePagosReturnExtended,
  ClienteDB,
  PedidoDB,
  PagoDB
} from '../../types'

export function usePagos(): UsePagosReturnExtended {
  const [pagos, setPagos] = useState<PagoDBWithUsuario[]>([])
  const [loading, setLoading] = useState<boolean>(false)

  const fetchPagosCliente = async (clienteId: string): Promise<PagoDBWithUsuario[]> => {
    setLoading(true)
    try {
      const { data, error } = await supabase
        .from('pagos')
        .select('*, usuario:perfiles(id, nombre)')
        .eq('cliente_id', clienteId)
        .order('created_at', { ascending: false })
      if (error) throw error
      const pagosData = (data || []) as PagoDBWithUsuario[]
      setPagos(pagosData)
      return pagosData
    } catch (error) {
      notifyError('Error al cargar pagos: ' + (error as Error).message)
      return []
    } finally {
      setLoading(false)
    }
  }

  const registrarPago = async (pago: PagoFormInput): Promise<PagoDBWithUsuario> => {
    try {
      const { data, error } = await supabase.from('pagos').insert([{
        cliente_id: pago.clienteId,
        pedido_id: pago.pedidoId || null,
        monto: parseFloat(String(pago.monto)),
        forma_pago: pago.formaPago || 'efectivo',
        referencia: pago.referencia || null,
        notas: pago.notas || null,
        usuario_id: pago.usuarioId || null
      }]).select('*, usuario:perfiles(id, nombre)').single()
      if (error) throw error
      const pagoData = data as PagoDBWithUsuario
      setPagos(prev => [pagoData, ...prev])
      return pagoData
    } catch (error) {
      notifyError('Error al registrar pago: ' + (error as Error).message)
      throw error
    }
  }

  const eliminarPago = async (pagoId: string): Promise<void> => {
    try {
      const { error } = await supabase.from('pagos').delete().eq('id', pagoId)
      if (error) throw error
      setPagos(prev => prev.filter(p => p.id !== pagoId))
    } catch (error) {
      notifyError('Error al eliminar pago: ' + (error as Error).message)
      throw error
    }
  }

  const obtenerResumenCuenta = async (clienteId: string): Promise<ResumenCuenta | null> => {
    try {
      const { data, error } = await supabase.rpc('obtener_resumen_cuenta_cliente', { p_cliente_id: clienteId })
      if (error) {
        const { data: cliente } = await supabase.from('clientes').select('*').eq('id', clienteId).single()
        const { data: pedidosCliente } = await supabase.from('pedidos').select('*').eq('cliente_id', clienteId)
        const { data: pagosCliente } = await supabase.from('pagos').select('*').eq('cliente_id', clienteId)

        const clienteTyped = cliente as ClienteDB | null
        const pedidosTyped = (pedidosCliente || []) as PedidoDB[]
        const pagosTyped = (pagosCliente || []) as PagoDB[]

        const totalCompras = pedidosTyped.reduce((s, p) => s + (p.total || 0), 0)
        const totalPagadoEnPedidos = pedidosTyped.reduce((s, p) => s + (p.monto_pagado || 0), 0)
        const totalPagosRegistrados = pagosTyped.reduce((s, p) => s + (p.monto || 0), 0)
        const saldoActual = totalCompras - totalPagadoEnPedidos - totalPagosRegistrados

        // Obtener última fecha correctamente (Math.max no funciona con Date)
        const ultimoPedidoFecha = pedidosTyped.reduce((max: Date, p) => {
          const fecha = new Date(p.created_at || 0)
          return fecha > max ? fecha : max
        }, new Date(0))

        const ultimoPagoFecha = pagosTyped.reduce((max: Date, p) => {
          const fecha = new Date(p.created_at || 0)
          return fecha > max ? fecha : max
        }, new Date(0))

        return {
          saldo_actual: saldoActual,
          limite_credito: clienteTyped?.limite_credito || 0,
          credito_disponible: (clienteTyped?.limite_credito || 0) - saldoActual,
          total_pedidos: pedidosTyped.length,
          total_compras: totalCompras,
          total_pagos: totalPagadoEnPedidos + totalPagosRegistrados,
          pedidos_pendientes_pago: pedidosTyped.filter(p => p.estado_pago !== 'pagado').length,
          ultimo_pedido: pedidosTyped.length ? ultimoPedidoFecha.toISOString() : null,
          ultimo_pago: pagosTyped.length ? ultimoPagoFecha.toISOString() : null
        }
      }
      return data as ResumenCuenta
    } catch {
      return null
    }
  }

  return { pagos, loading, fetchPagosCliente, registrarPago, eliminarPago, obtenerResumenCuenta }
}

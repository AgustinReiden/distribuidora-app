import { useState } from 'react'
import { supabase, notifyError } from './base'
import { useSucursal } from '../../contexts/SucursalContext'
import type {
  PagoDBWithUsuario,
  PagoFormInput,
  RegistrarPagoBatchInput,
  ResumenCuenta,
  UsePagosReturnExtended,
  ClienteDB,
  PedidoDB,
  PagoDB
} from '../../types'

export function usePagos(): UsePagosReturnExtended {
  const { currentSucursalId } = useSucursal()
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

  const fetchPagosPedido = async (pedidoId: string): Promise<PagoDBWithUsuario[]> => {
    try {
      const { data, error } = await supabase
        .from('pagos')
        .select('*, usuario:perfiles(id, nombre)')
        .eq('pedido_id', pedidoId)
        .order('created_at', { ascending: false })
      if (error) throw error
      return (data || []) as PagoDBWithUsuario[]
    } catch (error) {
      notifyError('Error al cargar pagos del pedido: ' + (error as Error).message)
      return []
    }
  }

  const registrarPago = async (pago: PagoFormInput): Promise<PagoDBWithUsuario> => {
    try {
      if (currentSucursalId == null) {
        throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
      }
      const insertRow: Record<string, unknown> = {
        cliente_id: pago.clienteId,
        pedido_id: pago.pedidoId || null,
        monto: parseFloat(String(pago.monto)),
        forma_pago: pago.formaPago || 'efectivo',
        referencia: pago.referencia || null,
        notas: pago.notas || null,
        usuario_id: pago.usuarioId || null,
        sucursal_id: currentSucursalId
      }
      // fecha (YYYY-MM-DD) se pasa solo si el caller la especificó; si no,
      // la BD usa CURRENT_DATE (default de la columna pagos.fecha).
      if (pago.fecha) insertRow.fecha = pago.fecha

      const { data, error } = await supabase.from('pagos').insert([insertRow])
        .select('*, usuario:perfiles(id, nombre)').single()
      if (error) throw error
      const pagoData = data as PagoDBWithUsuario
      setPagos(prev => [pagoData, ...prev])
      return pagoData
    } catch (error) {
      notifyError('Error al registrar pago: ' + (error as Error).message)
      throw error
    }
  }

  /**
   * Registra N pagos del mismo pedido en una sola operacion (uno por forma_pago).
   * Util para pagos combinados: cada forma genera una row separada en `pagos`,
   * facilitando los reportes. El trigger SQL `recalcular_monto_pagado_pedido`
   * (migration 035) recalcula `pedidos.monto_pagado` al insertar/anular pagos,
   * y a su vez el trigger BEFORE `actualizar_estado_pago_pedido` recalcula
   * `pedidos.estado_pago` en cascada.
   */
  const registrarPagosBatch = async (
    input: RegistrarPagoBatchInput
  ): Promise<PagoDBWithUsuario[]> => {
    try {
      if (currentSucursalId == null) {
        throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
      }
      const rows = input.pagos
        .filter(p => p.monto > 0)
        .map(p => ({
          cliente_id: input.clienteId,
          pedido_id: input.pedidoId,
          monto: p.monto,
          forma_pago: p.formaPago,
          fecha: input.fecha,
          notas: input.observaciones || null,
          usuario_id: input.usuarioId || null,
          sucursal_id: currentSucursalId,
        }))
      if (rows.length === 0) {
        throw new Error('No hay pagos validos para registrar')
      }
      const { data, error } = await supabase
        .from('pagos')
        .insert(rows)
        .select('*, usuario:perfiles(id, nombre)')
      if (error) throw error
      const pagosData = (data || []) as PagoDBWithUsuario[]
      setPagos(prev => [...pagosData, ...prev])
      return pagosData
    } catch (error) {
      notifyError('Error al registrar pagos: ' + (error as Error).message)
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

        const pedidosValidos = pedidosTyped.filter(p => p.estado !== 'cancelado')

        const totalCompras = pedidosValidos.reduce((s, p) => s + (p.total || 0), 0)
        // Use only pagos table as source of truth to avoid double-counting.
        // monto_pagado on pedidos is informational and often reflects the same payments.
        const totalPagosRegistrados = pagosTyped.reduce((s, p) => s + (p.monto || 0), 0)
        const saldoActual = totalCompras - totalPagosRegistrados

        // Obtener última fecha correctamente (Math.max no funciona con Date)
        const ultimoPedidoFecha = pedidosValidos.reduce((max: Date, p) => {
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
          total_pedidos: pedidosValidos.length,
          total_compras: totalCompras,
          total_pagos: totalPagosRegistrados,
          pedidos_pendientes_pago: pedidosValidos.filter(p => p.estado_pago !== 'pagado').length,
          ultimo_pedido: pedidosValidos.length ? ultimoPedidoFecha.toISOString() : null,
          ultimo_pago: pagosTyped.length ? ultimoPagoFecha.toISOString() : null
        }
      }
      return data as ResumenCuenta
    } catch {
      return null
    }
  }

  return {
    pagos,
    loading,
    fetchPagosCliente,
    fetchPagosPedido,
    registrarPago,
    registrarPagosBatch,
    eliminarPago,
    obtenerResumenCuenta,
  }
}

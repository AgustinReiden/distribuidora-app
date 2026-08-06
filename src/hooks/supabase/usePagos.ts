import { useState } from 'react'
import { supabase, notifyError } from './base'
import { useSucursal } from '../../contexts/SucursalContext'
import { retryWithBackoff, isTransientNetworkError } from '../../utils/retryWithBackoff'
import type {
  PagoDBWithUsuario,
  PagoFormInput,
  RegistrarPagoBatchInput,
  RegistrarPagoFifoInput,
  RegistrarPagoCombinadoFifoInput,
  RegistrarPagoFifoResult,
  PagoFifoAplicacion,
  ResumenCuenta,
  UsePagosReturnExtended,
  ClienteDB,
  PedidoDB,
  PagoDB
} from '../../types'

/** Violación de unique constraint: el reintento chocó con la fila que ya existe. */
const ES_DUPLICADO = (error: unknown): boolean =>
  (error as { code?: string } | null)?.code === '23505'

/**
 * Recupera las filas que dejó un intento anterior del mismo pago (mig 167).
 * Devuelve `null` si no hay UUIDs o si RLS no deja leerlas.
 */
async function pagosPorRequestId(ids: string[]): Promise<PagoDBWithUsuario[] | null> {
  if (ids.length === 0) return null
  const { data, error } = await supabase
    .from('pagos')
    .select('*, usuario:perfiles(id, nombre)')
    .in('client_request_id', ids)
  if (error) return null
  return (data || []) as PagoDBWithUsuario[]
}

const ERROR_DUPLICADO_SIN_LECTURA =
  'Este pago ya se había registrado en un intento anterior. Actualizá la pantalla para verlo; no lo cargues de nuevo.'

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
      const requestId = pago.clientRequestId || null
      if (requestId) insertRow.client_request_id = requestId

      const insertar = async (): Promise<PagoDBWithUsuario> => {
        const { data, error } = await supabase.from('pagos').insert([insertRow])
          .select('*, usuario:perfiles(id, nombre)').single()
        if (!error) return data as PagoDBWithUsuario

        // 23505 con UUID de idempotencia = este pago ya entró en un intento
        // anterior cuya respuesta no llegó (mig 167). No es un error: es el
        // mismo pago. Devolvemos la fila que ya existe.
        if (requestId && ES_DUPLICADO(error)) {
          const previos = await pagosPorRequestId([requestId])
          if (previos && previos.length === 1) return previos[0]
          throw new Error(ERROR_DUPLICADO_SIN_LECTURA)
        }
        throw error
      }

      // Con UUID el INSERT es idempotente, así que reintentar ante un error de
      // red es seguro: si la primera request sí llegó, el reintento devuelve
      // esa misma fila en vez de duplicarla.
      const pagoData = requestId
        ? await retryWithBackoff(insertar, { shouldRetry: isTransientNetworkError })
        : await insertar()

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
      // El UUID de idempotencia se aparea ANTES de filtrar: `clientRequestIds`
      // viene alineado por posición con `input.pagos`, y filtrar primero
      // correría los índices.
      const rows = input.pagos
        .map((p, i) => ({ p, requestId: input.clientRequestIds?.[i] || null }))
        .filter(({ p }) => p.monto > 0)
        .map(({ p, requestId }) => ({
          cliente_id: input.clienteId,
          pedido_id: input.pedidoId,
          monto: p.monto,
          forma_pago: p.formaPago,
          fecha: input.fecha,
          notas: input.observaciones || null,
          usuario_id: input.usuarioId || null,
          sucursal_id: currentSucursalId,
          client_request_id: requestId,
        }))
      if (rows.length === 0) {
        throw new Error('No hay pagos validos para registrar')
      }
      const requestIds = rows
        .map(r => r.client_request_id)
        .filter((id): id is string => !!id)
      const todosConRequestId = requestIds.length === rows.length

      const insertar = async (): Promise<PagoDBWithUsuario[]> => {
        const { data, error } = await supabase
          .from('pagos')
          .insert(rows)
          .select('*, usuario:perfiles(id, nombre)')
        if (!error) return (data || []) as PagoDBWithUsuario[]

        // Mismo caso que en registrarPago, pero el INSERT es atómico: o entraron
        // las N filas o ninguna. Si chocaron, ya están todas de un intento previo.
        if (todosConRequestId && ES_DUPLICADO(error)) {
          const previos = await pagosPorRequestId(requestIds)
          if (previos && previos.length === rows.length) return previos
          throw new Error(ERROR_DUPLICADO_SIN_LECTURA)
        }
        throw error
      }

      const pagosData = todosConRequestId
        ? await retryWithBackoff(insertar, { shouldRetry: isTransientNetworkError })
        : await insertar()

      setPagos(prev => [...pagosData, ...prev])
      return pagosData
    } catch (error) {
      notifyError('Error al registrar pagos: ' + (error as Error).message)
      throw error
    }
  }

  /**
   * Registra un pago de cliente y lo distribuye automaticamente sobre los
   * pedidos mas antiguos con saldo pendiente (FIFO). Sobrante queda como
   * saldo a favor (fila en pagos con pedido_id NULL).
   *
   * Solo admin o encargado (validado server-side en la RPC).
   */
  const registrarPagoFIFO = async (
    input: RegistrarPagoFifoInput
  ): Promise<RegistrarPagoFifoResult> => {
    try {
      if (currentSucursalId == null) {
        throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
      }
      const llamar = async () => {
        const { data, error } = await supabase.rpc('registrar_pago_cliente_fifo', {
          p_cliente_id: input.clienteId,
          p_monto: input.monto,
          p_forma_pago: input.formaPago,
          p_fecha: input.fecha ?? null,
          p_referencia: input.referencia ?? null,
          p_notas: input.notas ?? null,
          p_client_request_id: input.clientRequestId ?? null,
        })
        if (error) throw error
        return data
      }

      // La RPC es idempotente con p_client_request_id (mig 167): ante un error
      // de red se reintenta y el server devuelve la imputación original.
      const data = input.clientRequestId
        ? await retryWithBackoff(llamar, { shouldRetry: isTransientNetworkError })
        : await llamar()

      const raw = (data ?? {}) as {
        pago_ids?: number[]
        sobrante?: number
        monto_total?: number
        aplicaciones?: PagoFifoAplicacion[]
        credito_aplicado?: number
        idempotent_replay?: boolean
      }

      return {
        pagoIds: raw.pago_ids ?? [],
        sobrante: Number(raw.sobrante ?? 0),
        montoTotal: Number(raw.monto_total ?? input.monto),
        aplicaciones: raw.aplicaciones ?? [],
        creditoAplicado: Number(raw.credito_aplicado ?? 0),
        idempotentReplay: raw.idempotent_replay === true,
      }
    } catch (error) {
      notifyError('Error al registrar pago: ' + (error as Error).message)
      throw error
    }
  }

  /**
   * Registra un pago combinado (varias formas de pago) e imputa el total por
   * FIFO sobre los pedidos más antiguos con saldo pendiente, en una sola
   * transacción server-side (RPC `registrar_pago_combinado_cliente_fifo`).
   * Sobrante por forma queda como saldo a favor (fila con pedido_id NULL).
   *
   * Solo admin o encargado (validado server-side en la RPC).
   */
  const registrarPagoCombinadoFIFO = async (
    input: RegistrarPagoCombinadoFifoInput
  ): Promise<RegistrarPagoFifoResult> => {
    try {
      if (currentSucursalId == null) {
        throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
      }
      const llamar = async () => {
        const { data, error } = await supabase.rpc('registrar_pago_combinado_cliente_fifo', {
          p_cliente_id: input.clienteId,
          p_metodos: input.metodos.map(m => ({ monto: m.monto, forma_pago: m.formaPago })),
          p_fecha: input.fecha ?? null,
          p_referencia: input.referencia ?? null,
          p_notas: input.notas ?? null,
          p_client_request_id: input.clientRequestId ?? null,
        })
        if (error) throw error
        return data
      }

      const data = input.clientRequestId
        ? await retryWithBackoff(llamar, { shouldRetry: isTransientNetworkError })
        : await llamar()

      const raw = (data ?? {}) as {
        pago_ids?: number[]
        sobrante?: number
        monto_total?: number
        aplicaciones?: PagoFifoAplicacion[]
        credito_aplicado?: number
        idempotent_replay?: boolean
      }

      return {
        pagoIds: raw.pago_ids ?? [],
        sobrante: Number(raw.sobrante ?? 0),
        montoTotal: Number(raw.monto_total ?? 0),
        aplicaciones: raw.aplicaciones ?? [],
        creditoAplicado: Number(raw.credito_aplicado ?? 0),
        idempotentReplay: raw.idempotent_replay === true,
      }
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

  const actualizarFormaPagoDePago = async (
    pagoId: string,
    nuevaFormaPago: string,
  ): Promise<void> => {
    try {
      const { error } = await supabase.rpc('actualizar_forma_pago_pago', {
        p_pago_id: pagoId,
        p_forma_pago: nuevaFormaPago,
      })
      if (error) throw error
      setPagos(prev =>
        prev.map(p => (p.id === pagoId ? { ...p, forma_pago: nuevaFormaPago } : p)),
      )
    } catch (error) {
      notifyError('Error al actualizar forma de pago: ' + (error as Error).message)
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
    registrarPagoFIFO,
    registrarPagoCombinadoFIFO,
    eliminarPago,
    actualizarFormaPagoDePago,
    obtenerResumenCuenta,
  }
}

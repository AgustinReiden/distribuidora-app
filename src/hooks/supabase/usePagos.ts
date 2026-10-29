import { useState } from 'react'
import { supabase, notifyError } from './base'
import { useSucursal } from '../../contexts/SucursalContext'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { retryWithBackoff, isTransientNetworkError } from '../../utils/retryWithBackoff'
import { fechaLocalISO } from '../../utils/formatters'
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
import { traerTodo } from '../../utils/paginacion'
import { esPedidoDeBaja } from '../../utils/pedidoDeBaja'

interface CobroPedidoInput {
  pedidoId: string
  metodos: Array<{ monto: number; formaPago: string }>
  fecha?: string | null
  notas?: string | null
  referencia?: string | null
  clientRequestId?: string | null
}

/**
 * Cobra una boleta por la RPC `registrar_pagos_pedido` (#1246): `pagos` ya no
 * tiene INSERT REST. El server valida rol y cartera, monto, sobrepago, forma y
 * fecha, toma el cliente de la boleta y el usuario de la sesión; por eso no se
 * mandan. Devuelve las filas como las leía el INSERT REST
 * (`*, usuario:perfiles(id, nombre)`).
 *
 * Con `clientRequestId` la RPC es idempotente (mig 167): un reintento devuelve
 * las filas del cobro original en vez de duplicarlo, así que reintentar ante un
 * error de red es seguro.
 */
async function cobrarPedido(input: CobroPedidoInput): Promise<PagoDBWithUsuario[]> {
  const llamar = async () => {
    const { data, error } = await supabase.rpc('registrar_pagos_pedido', {
      p_pedido_id: input.pedidoId,
      p_metodos: input.metodos.map(m => ({ monto: m.monto, forma_pago: m.formaPago })),
      // Nunca `null`: p_fecha no tiene default (ver mig 230 en registrarPagoFIFO).
      p_fecha: input.fecha || fechaLocalISO(),
      p_notas: input.notas || null,
      p_referencia: input.referencia || null,
      p_client_request_id: input.clientRequestId || null,
    })
    if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el pago. Antes de reintentar, revisá la cuenta del cliente: puede haber quedado registrado.')
    return data
  }

  const data = input.clientRequestId
    ? await retryWithBackoff(llamar, { shouldRetry: isTransientNetworkError })
    : await llamar()

  return ((data as { pagos?: PagoDBWithUsuario[] | null } | null)?.pagos ?? [])
}

export function usePagos(): UsePagosReturnExtended {
  const { currentSucursalId } = useSucursal()
  const [pagos, setPagos] = useState<PagoDBWithUsuario[]>([])
  const [loading, setLoading] = useState<boolean>(false)

  const fetchPagosCliente = async (clienteId: string): Promise<PagoDBWithUsuario[]> => {
    setLoading(true)
    try {
      // Paginado por lo mismo que las otras dos consultas de la ficha
      // (`useFichaCliente`): hoy el cliente con más movimiento tiene 118 pagos,
      // pero la lista de la pestaña "Pagos" es de la misma modal y no tiene
      // sentido que la mitad aguante el crecimiento y la otra mitad no. El
      // desempate por `id` va porque `created_at` no es único.
      const pagosData = await traerTodo<PagoDBWithUsuario>(
        () => supabase
          .from('pagos')
          .select('*, usuario:perfiles(id, nombre)')
          .eq('cliente_id', clienteId)
          .order('created_at', { ascending: false })
          .order('id'),
        { etiqueta: 'pagos del cliente' },
      )
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
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar los pagos del pedido. Revisá tu conexión e intentá de nuevo.')
      return (data || []) as PagoDBWithUsuario[]
    } catch (error) {
      notifyError('Error al cargar pagos del pedido: ' + (error as Error).message)
      return []
    }
  }

  /**
   * Registra un pago. **Propaga el error sin notificarlo**: notifica quien
   * tiene contexto.
   *
   * Antes esta función hacía las dos cosas —`notifyError` y `throw`— y eso
   * obligaba a cada caller a elegir entre duplicar el toast o tragarse el
   * error. En el alta de pedido salían dos toasts contradictorios a la vez: el
   * genérico de acá y el del container, que es el único que dice lo que
   * importa (que el pedido SÍ se creó y no hay que recargarlo).
   *
   * Cobertura de los callers vivos: `ejecutarCreacionPedido` notifica con su
   * mensaje contextual; `ClientesContainer.handleConfirmarPago` y
   * `handleRegistrarPagoTransportista` no atrapan y el error llega al
   * `setError` de ModalRegistrarPago, que lo muestra inline en el formulario.
   */
  const registrarPago = async (pago: PagoFormInput): Promise<PagoDBWithUsuario> => {
    if (currentSucursalId == null) {
      throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
    }
    // Un pago sin boleta es un pago a cuenta: va por el FIFO de la ficha
    // (registrarPagoFIFO), que es sólo de admin y encargado.
    if (!pago.pedidoId) {
      throw new Error('Un pago sin pedido es un pago a cuenta: registralo desde la ficha del cliente.')
    }
    const [pagoData] = await cobrarPedido({
      pedidoId: pago.pedidoId,
      metodos: [{ monto: parseFloat(String(pago.monto)), formaPago: pago.formaPago || 'efectivo' }],
      fecha: pago.fecha,
      notas: pago.notas,
      referencia: pago.referencia,
      clientRequestId: pago.clientRequestId,
    })
    if (!pagoData) {
      throw new Error('El pago no se pudo confirmar. Revisá la cuenta del cliente antes de cargarlo de nuevo.')
    }

    setPagos(prev => [pagoData, ...prev])
    return pagoData
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
      const metodos = input.pagos.filter(p => p.monto > 0)
      if (metodos.length === 0) {
        throw new Error('No hay pagos validos para registrar')
      }

      // Una sola llamada, una sola clave de idempotencia. ModalPagoPedido arma
      // una por línea con la misma huella (`${huella}#${i}`), así que la
      // primera identifica el cobro entero y se repite igual en cada reintento.
      const pagosData = await cobrarPedido({
        pedidoId: input.pedidoId,
        metodos,
        fecha: input.fecha,
        notas: input.observaciones,
        clientRequestId: input.clientRequestIds?.find(Boolean) ?? null,
      })

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
          // mig 230: nunca `null`. Mandar null NO aplica el DEFAULT de la RPC
          // (los defaults sólo valen cuando el argumento se OMITE), así que
          // llegaba p_fecha NULL y el INSERT chocaba contra el NOT NULL de
          // pagos.fecha. La fecha se calcula acá, en TZ Argentina, que es la
          // misma que usa ahora el DEFAULT de la RPC.
          p_fecha: input.fecha ?? fechaLocalISO(),
          p_referencia: input.referencia ?? null,
          p_notas: input.notas ?? null,
          p_client_request_id: input.clientRequestId ?? null,
        })
        if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el pago. Antes de reintentar, revisá la cuenta del cliente: puede haber quedado registrado.')
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
          // mig 230: ver registrarPagoFIFO. Nunca `null`.
          p_fecha: input.fecha ?? fechaLocalISO(),
          p_referencia: input.referencia ?? null,
          p_notas: input.notas ?? null,
          p_client_request_id: input.clientRequestId ?? null,
        })
        if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el pago. Antes de reintentar, revisá la cuenta del cliente: puede haber quedado registrado.')
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
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la eliminación del pago. Antes de reintentar, revisá la cuenta del cliente: puede haber quedado registrado.')
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
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el cambio de forma de pago. Antes de reintentar, revisá la cuenta del cliente: puede haber quedado registrado.')
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
        // Paginado por lo mismo que la ficha: hoy ningún cliente llega a 1.000
        // pedidos ni a 1.000 pagos, pero si llegara los dos lados de la resta
        // truncarían por separado y el saldo dejaría de significar algo.
        const pedidosTyped = await traerTodo<PedidoDB>(
          () => supabase.from('pedidos').select('*').eq('cliente_id', clienteId).order('id'),
          { etiqueta: 'pedidos del cliente' },
        )
        const pagosTyped = await traerTodo<PagoDB>(
          () => supabase.from('pagos').select('*').eq('cliente_id', clienteId).order('id'),
          { etiqueta: 'pagos del cliente' },
        )

        const clienteTyped = cliente as ClienteDB | null

        // Sin las bajas (cancelado/anulado, #1080): actualizar_saldo_pedido
        // tampoco las cuenta como deuda.
        const pedidosValidos = pedidosTyped.filter(p => !esPedidoDeBaja(p.estado))

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

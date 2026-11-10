import { useState } from 'react'
import { supabase, notifyError } from './base'
import { useSucursal } from '../../contexts/SucursalContext'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { escrituraIdempotente } from '../../utils/escrituraIdempotente'
import { fechaLocalISO } from '../../utils/formatters'
import type {
  PagoDBWithUsuario,
  PagoRegistradoResultado,
  PagoFormInput,
  RegistrarPagoBatchInput,
  RegistrarPagoFifoInput,
  RegistrarPagoCombinadoFifoInput,
  RegistrarPagoFifoResult,
  PagoFifoAplicacion,
  ResumenCuenta,
  UsePagosReturnExtended
} from '../../types'
import { traerTodo } from '../../utils/paginacion'

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
const MENSAJE_PAGO_SIN_CONFIRMAR = 'Sin conexión: no se pudo confirmar el pago. Antes de reintentar, revisá la cuenta del cliente: puede haber quedado registrado.'

const MENSAJE_ELIMINAR_PAGO_SIN_CONFIRMAR = 'Sin conexión: no se pudo confirmar la eliminación del pago. Antes de reintentar, revisá la cuenta del cliente: puede haber quedado registrado.'
const MENSAJE_DESIMPUTAR_PAGO_SIN_CONFIRMAR = 'Sin conexión: no se pudo confirmar que el pago salió de la boleta. Antes de reintentar, revisá la cuenta del cliente: puede haber quedado hecho.'
const MENSAJE_FORMA_PAGO_SIN_CONFIRMAR = 'Sin conexión: no se pudo confirmar el cambio de forma de pago. Antes de reintentar, revisá la cuenta del cliente: puede haber quedado registrado.'

async function cobrarPedido(input: CobroPedidoInput): Promise<{ pagos: PagoDBWithUsuario[]; idempotentReplay: boolean }> {
  const llamar = async (signal: AbortSignal) => {
    const { data, error } = await supabase.rpc('registrar_pagos_pedido', {
      p_pedido_id: input.pedidoId,
      p_metodos: input.metodos.map(m => ({ monto: m.monto, forma_pago: m.formaPago })),
      // Nunca `null`: p_fecha no tiene default (ver mig 230 en registrarPagoFIFO).
      p_fecha: input.fecha || fechaLocalISO(),
      p_notas: input.notas || null,
      p_referencia: input.referencia || null,
      p_client_request_id: input.clientRequestId || null,
    }).abortSignal(signal)
    if (error) throw errorDeSupabase(error, MENSAJE_PAGO_SIN_CONFIRMAR)
    return data
  }

  // Sin `clientRequestId` no hay idempotencia: tiene plazo pero un solo intento.
  const data = await escrituraIdempotente(llamar, MENSAJE_PAGO_SIN_CONFIRMAR, {
    reintentar: Boolean(input.clientRequestId),
  })

  const raw = data as { pagos?: PagoDBWithUsuario[] | null; idempotent_replay?: boolean } | null
  return { pagos: raw?.pagos ?? [], idempotentReplay: raw?.idempotent_replay === true }
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

  /**
   * Los pagos de una boleta. Ante un error lo notifica y devuelve `null`, no `[]`:
   * "no cargó" no es "no tiene pagos", y el modal de pago decide con esto si un
   * cobro sin confirmar entró (#1410).
   */
  const fetchPagosPedido = async (pedidoId: string): Promise<PagoDBWithUsuario[] | null> => {
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
      return null
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
  const registrarPago = async (pago: PagoFormInput): Promise<PagoRegistradoResultado> => {
    if (currentSucursalId == null) {
      throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
    }
    // Un pago sin boleta es un pago a cuenta: va por el FIFO de la ficha
    // (registrarPagoFIFO), que es sólo de admin y encargado.
    if (!pago.pedidoId) {
      throw new Error('Un pago sin pedido es un pago a cuenta: registralo desde la ficha del cliente.')
    }
    const { pagos: [pagoData], idempotentReplay } = await cobrarPedido({
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
    return { ...pagoData, idempotentReplay }
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
  ): Promise<{ pagos: PagoDBWithUsuario[]; idempotentReplay: boolean }> => {
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
      const cobro = await cobrarPedido({
        pedidoId: input.pedidoId,
        metodos,
        fecha: input.fecha,
        notas: input.observaciones,
        clientRequestId: input.clientRequestIds?.find(Boolean) ?? null,
      })

      setPagos(prev => [...cobro.pagos, ...prev])
      return cobro
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
      const llamar = async (signal: AbortSignal) => {
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
        }).abortSignal(signal)
        if (error) throw errorDeSupabase(error, MENSAJE_PAGO_SIN_CONFIRMAR)
        return data
      }

      // La RPC es idempotente con p_client_request_id (mig 167): ante un error
      // de red se reintenta y el server devuelve la imputación original.
      const data = await escrituraIdempotente(llamar, MENSAJE_PAGO_SIN_CONFIRMAR, {
        reintentar: Boolean(input.clientRequestId),
      })

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
      const llamar = async (signal: AbortSignal) => {
        const { data, error } = await supabase.rpc('registrar_pago_combinado_cliente_fifo', {
          p_cliente_id: input.clienteId,
          p_metodos: input.metodos.map(m => ({ monto: m.monto, forma_pago: m.formaPago })),
          // mig 230: ver registrarPagoFIFO. Nunca `null`.
          p_fecha: input.fecha ?? fechaLocalISO(),
          p_referencia: input.referencia ?? null,
          p_notas: input.notas ?? null,
          p_client_request_id: input.clientRequestId ?? null,
        }).abortSignal(signal)
        if (error) throw errorDeSupabase(error, MENSAJE_PAGO_SIN_CONFIRMAR)
        return data
      }

      const data = await escrituraIdempotente(llamar, MENSAJE_PAGO_SIN_CONFIRMAR, {
        reintentar: Boolean(input.clientRequestId),
      })

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
      const llamar = async (signal: AbortSignal) => {
        const { error } = await supabase.from('pagos').delete().eq('id', pagoId).abortSignal(signal)
        if (error) throw errorDeSupabase(error, MENSAJE_ELIMINAR_PAGO_SIN_CONFIRMAR)
      }
      // Un DELETE por id es idempotente: si el primer intento entró, el segundo
      // borra 0 filas sin error. Por eso reintenta ante un fallo de red.
      await escrituraIdempotente(llamar, MENSAJE_ELIMINAR_PAGO_SIN_CONFIRMAR, { reintentar: true })
      setPagos(prev => prev.filter(p => p.id !== pagoId))
    } catch (error) {
      notifyError('Error al eliminar pago: ' + (error as Error).message)
      throw error
    }
  }

  /**
   * Quita de la boleta un pago que es saldo a favor aplicado (`esSaldoAFavorAplicado`): vuelve a
   * ser crédito suelto del cliente, sin tocar monto, fecha, forma ni `saldo_cuenta` (mig 479).
   * Sólo admin (validado en la RPC). Ese pago no se borra: el DELETE REST lo rechaza el server.
   */
  const desimputarPago = async (
    pagoId: string,
    pedidoId: string,
  ): Promise<{ yaEstabaSuelto: boolean; saldoAFavor: number }> => {
    try {
      const llamar = async (signal: AbortSignal) => {
        const { data, error } = await supabase.rpc('desimputar_pago', {
          p_pago_id: pagoId,
          p_pedido_id: pedidoId,
        }).abortSignal(signal)
        if (error) throw errorDeSupabase(error, MENSAJE_DESIMPUTAR_PAGO_SIN_CONFIRMAR)
        return data
      }
      // La RPC es idempotente: con el pago ya suelto contesta `ya_estaba_suelto`. Por eso
      // reintenta ante un fallo de red.
      const data = await escrituraIdempotente(llamar, MENSAJE_DESIMPUTAR_PAGO_SIN_CONFIRMAR, { reintentar: true })
      const raw = (data ?? {}) as { ya_estaba_suelto?: boolean; saldo_a_favor?: number | string | null }
      return {
        yaEstabaSuelto: raw.ya_estaba_suelto === true,
        saldoAFavor: Number(raw.saldo_a_favor ?? 0) || 0,
      }
    } catch (error) {
      notifyError('Error al quitar el pago de la boleta: ' + (error as Error).message)
      throw error
    }
  }

  const actualizarFormaPagoDePago = async (
    pagoId: string,
    nuevaFormaPago: string,
  ): Promise<void> => {
    try {
      const llamar = async (signal: AbortSignal) => {
        const { error } = await supabase.rpc('actualizar_forma_pago_pago', {
          p_pago_id: pagoId,
          p_forma_pago: nuevaFormaPago,
        }).abortSignal(signal)
        if (error) throw errorDeSupabase(error, MENSAJE_FORMA_PAGO_SIN_CONFIRMAR)
      }
      // La RPC no tiene clave de idempotencia: tiene plazo pero un solo intento.
      await escrituraIdempotente(llamar, MENSAJE_FORMA_PAGO_SIN_CONFIRMAR, { reintentar: false })
      setPagos(prev =>
        prev.map(p => (p.id === pagoId ? { ...p, forma_pago: nuevaFormaPago } : p)),
      )
    } catch (error) {
      notifyError('Error al actualizar forma de pago: ' + (error as Error).message)
      throw error
    }
  }

  /**
   * El resumen de cuenta lo calcula el server (`obtener_resumen_cuenta_cliente`).
   * Si la RPC falla devuelve `null` ("no disponible"): NO se recalcula el saldo en
   * el front. Ese respaldo era compras menos pagos y contaba los vales blancos
   * como deuda (`monto_pagado = total` y cero filas en `pagos`), o sea, un saldo
   * distinto al real mostrado como si fuera el real (COB-F-6).
   */
  const obtenerResumenCuenta = async (clienteId: string): Promise<ResumenCuenta | null> => {
    try {
      const { data, error } = await supabase.rpc('obtener_resumen_cuenta_cliente', { p_cliente_id: clienteId })
      if (error || !data) return null
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
    desimputarPago,
    actualizarFormaPagoDePago,
    obtenerResumenCuenta,
  }
}

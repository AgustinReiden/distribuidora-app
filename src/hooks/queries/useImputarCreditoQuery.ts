/**
 * Imputar un crédito a favor del cliente (pago sin pedido: nota de crédito de
 * venta, anticipo o sobrante) a un pedido ELEGIDO.
 *
 * Escritura sólo por la RPC `imputar_credito_a_pedido`: imputa LEAST(crédito,
 * faltante del pedido, monto pedido) y deja el resto a favor en una fila nueva.
 * Sólo admin/encargado (el espejo en la UI es `puedeRegistrarPagoCliente`). Es
 * idempotente con `client_request_id`, el mismo ledger que los pagos (mig 167).
 *
 * La cuenta previa que ve el usuario vive en `utils/imputacionCredito`.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { retryWithBackoff, isTransientNetworkError } from '../../utils/retryWithBackoff'
import { traerTodo } from '../../utils/paginacion'
import type { PedidoParaImputar } from '../../utils/imputacionCredito'

export const imputacionCreditoKeys = {
  // Bajo el prefijo `pedidos`: cualquier mutation que invalide pedidos (un pago,
  // una entrega, una cancelación) también refresca los faltantes del selector.
  pedidosCliente: (sucursalId: number | null, clienteId: string) =>
    ['pedidos', 'imputables', sucursalId, clienteId] as const,
  origenNC: (sucursalId: number | null, notaCreditoId: string) =>
    ['notas_credito_venta', sucursalId, 'origen', notaCreditoId] as const,
}

/**
 * Pedidos no cancelados del cliente con lo necesario para calcular el faltante.
 * El filtro fino (faltante > 0, sin el pedido de origen) lo hace
 * `pedidosImputables`, que es lo que está testeado.
 */
export function usePedidosParaImputarQuery(clienteId: string | undefined, enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: imputacionCreditoKeys.pedidosCliente(currentSucursalId, clienteId || ''),
    queryFn: () =>
      traerTodo<PedidoParaImputar>(
        () => supabase
          .from('pedidos')
          .select('id, fecha, created_at, total, monto_pagado, estado')
          .eq('cliente_id', clienteId!)
          .neq('estado', 'cancelado')
          .order('id'),
        { etiqueta: 'pedidos del cliente' },
      ),
    enabled: !!clienteId && enabled,
    staleTime: 0,
  })
}

/**
 * Pedido de origen de una NC, cuando quien abre el modal no lo sabe (la lista de
 * pagos de la ficha sólo trae `nota_credito_id`). Sirve para excluirlo del
 * selector y para mostrarlo; el servidor rechaza igual imputarle a ese pedido.
 */
export function usePedidoOrigenNCQuery(notaCreditoId: string | null | undefined, enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: imputacionCreditoKeys.origenNC(currentSucursalId, notaCreditoId || ''),
    queryFn: async (): Promise<string | null> => {
      const { data, error } = await supabase
        .from('notas_credito_venta')
        .select('id, pedido_id')
        .eq('id', notaCreditoId!)
        .maybeSingle()
      if (error) throw error
      const row = data as { pedido_id?: string | number | null } | null
      return row?.pedido_id != null ? String(row.pedido_id) : null
    },
    enabled: !!notaCreditoId && enabled,
    staleTime: 5 * 60 * 1000,
  })
}

export interface ImputarCreditoInput {
  pagoId: string
  pedidoId: string
  /** `null` = todo lo posible (LEAST(crédito, faltante)). */
  monto: number | null
  clientRequestId: string
}

export interface ImputarCreditoResult {
  pagoId: string
  pedidoId: string
  montoImputado: number
  restoAFavor: number
  /** Fila nueva con el resto a favor; `null` si el crédito se consumió entero. */
  pagoRestoId: string | null
  idempotentReplay: boolean
}

async function imputarCredito(input: ImputarCreditoInput): Promise<ImputarCreditoResult> {
  const llamar = async () => {
    const { data, error } = await supabase.rpc('imputar_credito_a_pedido', {
      p_pago_id: Number(input.pagoId),
      p_pedido_id: Number(input.pedidoId),
      p_monto: input.monto,
      p_client_request_id: input.clientRequestId,
    })
    // Los errores de negocio llegan como excepción con el mensaje en español:
    // se muestran tal cual. El `code` se conserva para que el reintento no
    // confunda un rechazo del servidor con una caída de red.
    if (error) throw Object.assign(new Error(error.message), { code: error.code })
    return data
  }
  // Idempotente por client_request_id: ante un error de red se reintenta y el
  // server devuelve la imputación original (idempotent_replay).
  const data = await retryWithBackoff(llamar, { shouldRetry: isTransientNetworkError })

  const raw = (data ?? {}) as {
    pago_id?: number | string
    pedido_id?: number | string
    monto_imputado?: number | string
    resto_a_favor?: number | string
    pago_resto_id?: number | string | null
    idempotent_replay?: boolean
  }
  return {
    pagoId: String(raw.pago_id ?? input.pagoId),
    pedidoId: String(raw.pedido_id ?? input.pedidoId),
    montoImputado: Number(raw.monto_imputado ?? 0),
    restoAFavor: Number(raw.resto_a_favor ?? 0),
    pagoRestoId: raw.pago_resto_id != null ? String(raw.pago_resto_id) : null,
    idempotentReplay: raw.idempotent_replay === true,
  }
}

/**
 * En `onSuccess` invalida por prefijo todo lo que mira el saldo o el estado de
 * pago: pedidos (faltante y `estado_pago`), clientes (`saldo_cuenta`), las NCs
 * (el crédito disponible de cada una), pagos y deudores en mora. La ficha del
 * cliente lee pagos y saldo con estado local, no con TanStack: refresca ella
 * misma en `onImputado`.
 */
export function useImputarCreditoMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: imputarCredito,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['pagos'] })
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
      queryClient.invalidateQueries({ queryKey: ['clientes'] })
      queryClient.invalidateQueries({ queryKey: ['notas_credito_venta'] })
      queryClient.invalidateQueries({ queryKey: ['deudores-mora'] })
    },
  })
}

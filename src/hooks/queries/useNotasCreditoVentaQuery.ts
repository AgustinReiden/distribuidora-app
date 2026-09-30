/**
 * Notas de crédito de VENTA (#833, mig 276). Las de compras viven en
 * `useNotasCreditoQuery`.
 *
 * Lectura directa de `notas_credito_venta` (RLS: admin/encargado de la sucursal)
 * con sus ítems. El embed de `productos` sale de `nota_credito_venta_items`, que
 * tiene una sola FK a productos; `perfiles` NO se embebe a propósito: la tabla
 * tiene dos FKs a perfiles (`usuario_id`, `anulada_por`) y un embed sin hint da
 * PGRST201 y rompe la consulta entera (CLAUDE.md, trampa 5).
 *
 * Escritura sólo por RPC: `crear_nota_credito_venta` (wrapper idempotente con
 * `client_request_id`, mismo ledger que los pagos) y `anular_nota_credito_venta`.
 * Ninguna de las dos toca el pedido ni el stock; mueven el saldo del cliente a
 * través del pago de crédito, por eso invalidan clientes, pagos y pedidos.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import type { NotaCreditoVentaDB } from '../../types'
import type { MotivoNCVenta } from '../../utils/notaCreditoVenta'

const NC_VENTA_SELECT = '*, items:nota_credito_venta_items(*, producto:productos(id, nombre))' as const

export const notasCreditoVentaKeys = {
  all: (sucursalId: number | null) => ['notas_credito_venta', sucursalId] as const,
  byCliente: (sucursalId: number | null, clienteId: string) =>
    [...notasCreditoVentaKeys.all(sucursalId), 'cliente', clienteId] as const,
  byPedido: (sucursalId: number | null, pedidoId: string) =>
    [...notasCreditoVentaKeys.all(sucursalId), 'pedido', pedidoId] as const,
}

async function fetchNotasCreditoVenta(
  columna: 'cliente_id' | 'pedido_id',
  id: string,
): Promise<NotaCreditoVentaDB[]> {
  const { data, error } = await supabase
    .from('notas_credito_venta')
    .select(NC_VENTA_SELECT)
    .eq(columna, id)
    .order('fecha', { ascending: false })
    .order('id', { ascending: false })
  if (error) throw error
  return (data || []) as unknown as NotaCreditoVentaDB[]
}

/** NCs del cliente (vigentes y anuladas), para la ficha. */
export function useNotasCreditoVentaClienteQuery(clienteId: string | undefined, enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: notasCreditoVentaKeys.byCliente(currentSucursalId, clienteId || ''),
    queryFn: () => fetchNotasCreditoVenta('cliente_id', clienteId!),
    enabled: !!clienteId && enabled,
    staleTime: 60 * 1000,
  })
}

/** NCs de un pedido: el modal las usa para no acreditar dos veces la misma línea. */
export function useNotasCreditoVentaPedidoQuery(pedidoId: string | undefined, enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: notasCreditoVentaKeys.byPedido(currentSucursalId, pedidoId || ''),
    queryFn: () => fetchNotasCreditoVenta('pedido_id', pedidoId!),
    enabled: !!pedidoId && enabled,
    staleTime: 0,
  })
}

export interface CrearNotaCreditoVentaInput {
  pedidoId: string
  clienteId: string
  items: Array<{ pedido_item_id: number; cantidad: number }>
  motivo: MotivoNCVenta
  observaciones?: string | null
  clientRequestId: string
}

export interface CrearNotaCreditoVentaResult {
  nota_credito_id: number
  pago_id: number
  total: number
  fecha: string
  idempotent_replay?: boolean
}

async function crearNotaCreditoVenta(input: CrearNotaCreditoVentaInput): Promise<CrearNotaCreditoVentaResult> {
  const { data, error } = await supabase.rpc('crear_nota_credito_venta', {
    p_pedido_id: Number(input.pedidoId),
    p_cliente_id: Number(input.clienteId),
    p_items: input.items,
    p_motivo: input.motivo,
    p_observaciones: input.observaciones || null,
    p_client_request_id: input.clientRequestId,
  })
  if (error) throw error
  return data as CrearNotaCreditoVentaResult
}

async function anularNotaCreditoVenta(input: { notaCreditoId: string; motivo?: string | null }): Promise<void> {
  const { error } = await supabase.rpc('anular_nota_credito_venta', {
    p_nota_credito_id: Number(input.notaCreditoId),
    p_motivo: input.motivo || null,
  })
  if (error) throw error
}

function useInvalidarTrasNC() {
  const queryClient = useQueryClient()
  return () => {
    // Prefijos: la mutation no conoce la sucursal ni los filtros de cada lista.
    queryClient.invalidateQueries({ queryKey: ['notas_credito_venta'] })
    queryClient.invalidateQueries({ queryKey: ['clientes'] })
    queryClient.invalidateQueries({ queryKey: ['pedidos'] })
  }
}

export function useCrearNotaCreditoVentaMutation() {
  const invalidar = useInvalidarTrasNC()
  return useMutation({ mutationFn: crearNotaCreditoVenta, onSuccess: invalidar })
}

export function useAnularNotaCreditoVentaMutation() {
  const invalidar = useInvalidarTrasNC()
  return useMutation({ mutationFn: anularNotaCreditoVenta, onSuccess: invalidar })
}

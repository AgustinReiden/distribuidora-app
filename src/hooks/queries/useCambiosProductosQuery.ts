/**
 * TanStack Query hooks para Cambios de Productos cliente↔depósito
 *
 * Llama a la RPC atómica registrar_cambio_producto que:
 *   - Suma stock al producto devuelto
 *   - Resta stock al producto entregado
 *   - Ajusta saldo_cuenta del cliente con la diferencia de precio
 *   - Inserta el registro en cambios_productos
 */
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { productosKeys } from './useProductosQuery'
import { clientesKeys } from './useClientesQuery'

export const cambiosProductosKeys = {
  all: (sucursalId: number | null) => ['cambios_productos', sucursalId] as const,
  lists: (sucursalId: number | null) => [...cambiosProductosKeys.all(sucursalId), 'list'] as const,
}

export interface RegistrarCambioInput {
  clienteId: string
  productoDevueltoId: string
  cantidadDevuelta: number
  productoEntregadoId: string
  cantidadEntregada: number
  observaciones?: string
}

async function registrarCambio(input: RegistrarCambioInput): Promise<number> {
  const { data, error } = await supabase.rpc('registrar_cambio_producto', {
    p_cliente_id: Number(input.clienteId),
    p_producto_devuelto_id: Number(input.productoDevueltoId),
    p_cantidad_devuelta: input.cantidadDevuelta,
    p_producto_entregado_id: Number(input.productoEntregadoId),
    p_cantidad_entregada: input.cantidadEntregada,
    p_observaciones: input.observaciones || null,
  })

  if (error) throw error
  return data as number
}

/**
 * Hook para registrar un cambio de productos.
 * Invalida cache de productos (stock) y clientes (saldo_cuenta).
 */
export function useRegistrarCambioProductoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: registrarCambio,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: productosKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: productosKeys.stockBajo(currentSucursalId, 10) })
      queryClient.invalidateQueries({ queryKey: clientesKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: cambiosProductosKeys.lists(currentSucursalId) })
    },
  })
}

// ============================================================================
// Cambio como PARADA del recorrido (mig 089)
// ============================================================================

/**
 * Crea un pedido especial canal='cambio' (total 0) + su detalle en
 * recorrido_cambios para sumarlo como parada del recorrido. NO ajusta
 * stock/saldo todavía (eso ocurre al completar la parada). Devuelve el
 * pedido_id creado.
 */
async function crearPedidoCambioEnRuta(input: RegistrarCambioInput): Promise<number> {
  const { data, error } = await supabase.rpc('crear_pedido_cambio_en_ruta', {
    p_cliente_id: Number(input.clienteId),
    p_producto_devuelto_id: Number(input.productoDevueltoId),
    p_cantidad_devuelta: input.cantidadDevuelta,
    p_producto_entregado_id: Number(input.productoEntregadoId),
    p_cantidad_entregada: input.cantidadEntregada,
    p_observaciones: input.observaciones || null,
  })

  if (error) throw error
  return data as number
}

/**
 * Hook para crear una parada de cambio. Solo invalida pedidos (la parada
 * aparece en el pool rutable); stock/saldo no se tocan hasta completarla.
 */
export function useCrearPedidoCambioEnRutaMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: crearPedidoCambioEnRuta,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
    },
  })
}

/**
 * Aplica el cambio real de una parada al completarla (suma stock devuelto,
 * resta entregado, ajusta saldo_cuenta, inserta cambios_productos). Idempotente
 * en el backend. Devuelve el cambio_producto_id.
 */
async function aplicarCambioDeParada(pedidoId: string): Promise<number | null> {
  const { data, error } = await supabase.rpc('aplicar_cambio_de_parada', {
    p_pedido_id: Number(pedidoId),
  })

  if (error) throw error
  return (data as number | null) ?? null
}

/**
 * Hook para aplicar el cambio de una parada. Invalida productos (stock),
 * clientes (saldo), la ruta activa del chofer y pedidos.
 */
export function useAplicarCambioParadaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: aplicarCambioDeParada,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: productosKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: productosKeys.stockBajo(currentSucursalId, 10) })
      queryClient.invalidateQueries({ queryKey: clientesKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: cambiosProductosKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: ['recorrido-activo'] })
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
    },
  })
}

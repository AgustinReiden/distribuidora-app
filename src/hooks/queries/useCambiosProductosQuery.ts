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

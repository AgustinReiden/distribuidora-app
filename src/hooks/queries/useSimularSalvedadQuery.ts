/**
 * Hook dry-run para detectar promos afectadas por una salvedad antes de confirmarla.
 * Llama al RPC `simular_salvedad_promo_impacto` (migración 013).
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'

export interface PromoImpactoSalvedad {
  promocion_id: number
  promo_nombre: string
  bonif_actual: number
  bonif_esperada: number
  delta: number
  descripcion_regalo: string | null
  sera_eliminada: boolean
}

async function fetchSimularSalvedad(
  pedidoId: string | number,
  pedidoItemId: string | number,
  cantidadAfectada: number,
): Promise<PromoImpactoSalvedad[]> {
  if (!cantidadAfectada || cantidadAfectada <= 0) return []
  const { data, error } = await supabase.rpc('simular_salvedad_promo_impacto', {
    p_pedido_id: Number(pedidoId),
    p_pedido_item_id: Number(pedidoItemId),
    p_cantidad_afectada: cantidadAfectada,
  })
  if (error) {
    if (error.message.includes('does not exist')) return []
    throw error
  }
  return (data as PromoImpactoSalvedad[]) ?? []
}

/**
 * Retorna las bonificaciones que quedarian reducidas/eliminadas por una salvedad
 * sobre el item indicado. Array vacio = la salvedad no rompe ninguna promo.
 * Se refresca reactivamente al cambiar `cantidadAfectada`.
 */
export function useSimularSalvedadPromoImpactoQuery(
  pedidoId: string | number | null | undefined,
  pedidoItemId: string | number | null | undefined,
  cantidadAfectada: number,
) {
  const { currentSucursalId } = useSucursal()
  const enabled = !!pedidoId && !!pedidoItemId && cantidadAfectada > 0 && !!currentSucursalId
  return useQuery({
    queryKey: [
      'simular_salvedad_promo_impacto',
      currentSucursalId,
      pedidoId,
      pedidoItemId,
      cantidadAfectada,
    ] as const,
    queryFn: () => fetchSimularSalvedad(pedidoId!, pedidoItemId!, cantidadAfectada),
    enabled,
    staleTime: 10 * 1000,
  })
}

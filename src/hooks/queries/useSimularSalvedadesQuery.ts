/**
 * Dry-run multi-item: en que queda cada regalo del pedido si se confirma un
 * lote entero de salvedades. Llama al RPC `simular_salvedades_promo_impacto`
 * (migracion 174).
 *
 * El de a un item vive en `useSimularSalvedadQuery` y sirve para el modal del
 * chofer; este es el que necesita la "Entrega con salvedad", donde se marcan
 * varios productos de una y el resumen tiene que decir la verdad sobre los
 * regalos antes de confirmar.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'

export interface SalvedadSimulada {
  pedidoItemId: string | number
  cantidadAfectada: number
}

export interface RegaloSimulado {
  pedido_item_id: number
  promocion_id: number | null
  promo_nombre: string | null
  producto_id: number
  producto_nombre: string | null
  descripcion_regalo: string | null
  cantidad_actual: number
  cantidad_final: number
  delta: number
  sera_eliminada: boolean
}

async function fetchSimularSalvedades(
  pedidoId: string | number,
  salvedades: SalvedadSimulada[],
): Promise<RegaloSimulado[]> {
  const { data, error } = await supabase.rpc('simular_salvedades_promo_impacto', {
    p_pedido_id: Number(pedidoId),
    p_salvedades: salvedades.map(s => ({
      pedido_item_id: Number(s.pedidoItemId),
      cantidad_afectada: s.cantidadAfectada,
    })),
  })
  if (error) {
    // El RPC recien existe desde la mig 174; si el deploy de base todavia no
    // paso, el modal sigue funcionando sin la seccion de regalos.
    if (error.message.includes('does not exist')) return []
    throw error
  }
  return (data as RegaloSimulado[]) ?? []
}

/**
 * Una fila por linea de regalo del pedido, con la cantidad en la que queda si
 * se confirman estas salvedades. Array vacio = el pedido no tiene regalos.
 */
export function useSimularSalvedadesPromoImpactoQuery(
  pedidoId: string | number | null | undefined,
  salvedades: SalvedadSimulada[],
  opciones?: { enabled?: boolean },
) {
  const { currentSucursalId } = useSucursal()
  // Clave estable: el orden de seleccion no deberia disparar un refetch.
  const firma = salvedades
    .map(s => `${s.pedidoItemId}:${s.cantidadAfectada}`)
    .sort()
    .join('|')
  const enabled = !!pedidoId && !!currentSucursalId && (opciones?.enabled ?? true)

  return useQuery({
    queryKey: ['simular_salvedades_promo_impacto', currentSucursalId, pedidoId, firma] as const,
    queryFn: () => fetchSimularSalvedades(pedidoId!, salvedades),
    enabled,
    staleTime: 10 * 1000,
  })
}

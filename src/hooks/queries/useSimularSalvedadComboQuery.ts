/**
 * Dry-run de los combos (#1192): si el cliente rechaza parte de un combo, el
 * combo se rompe y el total puede subir. Llama al RPC
 * `simular_salvedades_combo_impacto`, que aplica la misma regla que
 * `registrar_salvedad` sin escribir nada. Sirve para una salvedad suelta
 * (ModalSalvedadItem) y para un lote (ModalEntregaConSalvedad): rehacer el
 * combo no depende del orden, así que el lote da lo mismo que confirmarlas de
 * a una.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { normalizarImpactoCombos, type ComboImpactoSalvedad } from '../../utils/comboSalvedad'

export interface SalvedadComboSimulada {
  pedidoItemId: string | number
  cantidadAfectada: number
  /** El motivo decide: sólo `cliente_rechaza` rompe el combo. */
  motivo: string
}

async function fetchSimularSalvedadesCombo(
  pedidoId: string | number,
  salvedades: SalvedadComboSimulada[],
): Promise<ComboImpactoSalvedad[]> {
  const { data, error } = await supabase.rpc('simular_salvedades_combo_impacto', {
    p_pedido_id: Number(pedidoId),
    p_salvedades: salvedades.map(s => ({
      pedido_item_id: Number(s.pedidoItemId),
      cantidad_afectada: s.cantidadAfectada,
      motivo: s.motivo,
    })),
  })
  if (error) {
    // Sin la migración de #1192 el RPC no existe: el modal sigue sin la sección.
    if (error.message.includes('does not exist')) return []
    throw errorDeSupabase(error, 'Sin conexión: no se pudo calcular el efecto de la salvedad en los combos. Revisá la señal e intentá de nuevo.')
  }
  return normalizarImpactoCombos(data)
}

/**
 * Un elemento por combo del pedido que tocan las salvedades, con los combos
 * que quedan y el recargo. Array vacío = no hay combo de por medio.
 */
export function useSimularSalvedadesComboImpactoQuery(
  pedidoId: string | number | null | undefined,
  salvedades: SalvedadComboSimulada[],
  opciones?: { enabled?: boolean },
) {
  const { currentSucursalId } = useSucursal()
  // Clave estable: el orden de selección no debería disparar un refetch.
  const firma = salvedades
    .map(s => `${s.pedidoItemId}:${s.cantidadAfectada}:${s.motivo}`)
    .sort()
    .join('|')
  const enabled = !!pedidoId && !!currentSucursalId && salvedades.length > 0 && (opciones?.enabled ?? true)

  return useQuery({
    queryKey: ['simular_salvedades_combo_impacto', currentSucursalId, pedidoId, firma] as const,
    queryFn: () => fetchSimularSalvedadesCombo(pedidoId!, salvedades),
    enabled,
    staleTime: 10 * 1000,
  })
}

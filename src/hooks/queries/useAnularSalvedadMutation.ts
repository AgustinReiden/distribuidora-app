/**
 * Hook mutation para ANULAR una salvedad.
 *
 * Backend: RPC `anular_salvedad` (mig 244, decision #621). Solo admin
 * (`es_admin()` desde la mig 252); el espejo en la UI es `puedeAnularSalvedad`.
 *
 * Anular NO es resolver. `resolver_salvedad` sólo dice quien se hace cargo del
 * monto; anular deshace la salvedad entera: restituye la linea del pedido
 * --el cliente vuelve a pagar lo que se le habia sacado--, recalcula los
 * totales, corrige el stock si la salvedad lo habia devuelto y anula la merma
 * si la habia generado. Por eso vive en su propia accion, con su propia
 * confirmacion, y por eso `resolver_salvedad` rechaza 'anulada' desde la 244.
 *
 * El RPC devuelve `{ success: false, error, codigo }` con HTTP 200 para las
 * negativas de negocio (salvedad sobre un regalo de promocion, restitucion que
 * volveria a disparar una promo, merma no encontrada, ya anulada). Se convierten
 * a Error para que TanStack Query dispare `onError`.
 */
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { mermasReporteKeys } from './useMermasReporteQuery'
import type { AnularSalvedadInput } from '../../types'

async function anularSalvedad(input: AnularSalvedadInput): Promise<{ success: true }> {
  const { data, error } = await supabase.rpc('anular_salvedad', {
    p_salvedad_id: parseInt(input.salvedadId, 10),
    p_notas: input.notas,
  })
  if (error) throw error

  const raw = (data ?? {}) as { success?: boolean; error?: string; codigo?: string }
  if (!raw.success) {
    throw new Error(raw.error || 'No se pudo anular la salvedad')
  }
  return { success: true }
}

/**
 * En `onSuccess` invalida pedidos, productos y las dos familias de mermas: la
 * anulacion mueve las tres cosas (el total del pedido, el stock cuando la
 * salvedad lo habia devuelto, y el libro de mermas cuando era por dañado o
 * vencido). Las claves van por prefijo porque la mutation no conoce la sucursal
 * ni el rango del reporte.
 */
export function useAnularSalvedadMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: anularSalvedad,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
      queryClient.invalidateQueries({ queryKey: ['productos'] })
      queryClient.invalidateQueries({ queryKey: ['mermas'] })
      queryClient.invalidateQueries({ queryKey: mermasReporteKeys.all })
    },
  })
}

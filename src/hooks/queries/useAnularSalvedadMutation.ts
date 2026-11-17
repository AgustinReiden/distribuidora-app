/**
 * Hook mutation para ANULAR una salvedad.
 *
 * Backend: RPC `anular_salvedad` (mig 244, decision #621). Solo admin
 * (`es_admin()` desde la mig 252); el espejo en la UI es `puedeAnularSalvedad`.
 *
 * Anular NO es resolver. `resolver_salvedad` sólo dice quien se hace cargo del
 * monto; anular deshace la salvedad entera: restituye la linea del pedido,
 * recalcula los totales, repone el cobro que la salvedad habia recortado de la
 * boleta (mig 497, #1559 COB-1: con tope en lo que la boleta debe), corrige el stock si la salvedad lo habia devuelto y anula la merma
 * si la habia generado. Por eso vive en su propia accion, con su propia
 * confirmacion, y por eso `resolver_salvedad` rechaza 'anulada' desde la 244.
 *
 * El RPC devuelve `{ success: false, error, codigo }` con HTTP 200 para las
 * negativas de negocio (salvedad sobre un regalo de promocion, restitucion que
 * volveria a disparar una promo, merma no encontrada, ya anulada, pedido con una
 * nota de credito vigente --`nota_credito_vigente`, #1163-- y pedido editado
 * despues de la salvedad --`pedido_editado`, #1161--). Se convierten a Error
 * para que TanStack Query dispare `onError`; el mensaje del RPC llega al modal
 * tal cual.
 *
 * Si sale bien, la respuesta trae `cobro_repuesto` y `cobro_sin_reponer`: lo que
 * volvio a la boleta y lo que no pudo volver (el cobro ya no esta, o la boleta ya
 * no debe esa plata). COB-A (#1595): el hook los devuelve y el modal avisa lo que
 * quedo sin reponer, en vez de descartarlos.
 */
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { mermasReporteKeys } from './useMermasReporteQuery'
import { salvedadesKeys } from './useSalvedadesQuery'
import type { AnularSalvedadInput } from '../../types'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { invalidarCuposPromo } from './cuposPromoCache'

/** Lo que devuelve `anular_salvedad` cuando anula, ya como numeros. */
export interface ResultadoAnularSalvedad {
  success: true
  /** Cobro de la boleta que la anulacion repuso. */
  cobroRepuesto: number
  /** Cobro recortado por la salvedad que NO se pudo reponer. 0 si volvio todo. */
  cobroSinReponer: number
}

/** Un monto de la respuesta: lo que no es un numero finito y positivo es 0. */
function montoDeRespuesta(valor: unknown): number {
  const n = Number(valor)
  return Number.isFinite(n) && n > 0 ? n : 0
}

async function anularSalvedad(input: AnularSalvedadInput): Promise<ResultadoAnularSalvedad> {
  const { data, error } = await supabase.rpc('anular_salvedad', {
    p_salvedad_id: parseInt(input.salvedadId, 10),
    p_notas: input.notas,
  })
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la anulación de la salvedad. Revisá si quedó hecho antes de reintentar.')

  const raw = (data ?? {}) as {
    success?: boolean
    error?: string
    codigo?: string
    cobro_repuesto?: unknown
    cobro_sin_reponer?: unknown
  }
  if (!raw.success) {
    throw new Error(raw.error || 'No se pudo anular la salvedad')
  }
  return {
    success: true,
    cobroRepuesto: montoDeRespuesta(raw.cobro_repuesto),
    cobroSinReponer: montoDeRespuesta(raw.cobro_sin_reponer),
  }
}

/**
 * En `onSuccess` invalida pedidos, clientes, productos y las dos familias de
 * mermas: la anulacion mueve todo eso (el total del pedido y con él el saldo del
 * cliente, el stock cuando la salvedad lo habia devuelto, y el libro de mermas
 * cuando era por dañado o vencido). Y la lista y los KPIs de salvedades, donde
 * la anulada cambia de estado. Las claves van por prefijo porque la mutation no conoce la sucursal
 * ni el rango del reporte.
 */
export function useAnularSalvedadMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: anularSalvedad,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
      // FRT-2: anular restituye la línea y sube el total de la boleta: cambia el
      // saldo del cliente.
      queryClient.invalidateQueries({ queryKey: ['clientes'] })
      queryClient.invalidateQueries({ queryKey: ['productos'] })
      queryClient.invalidateQueries({ queryKey: ['mermas'] })
      queryClient.invalidateQueries({ queryKey: mermasReporteKeys.all })
      queryClient.invalidateQueries({ queryKey: salvedadesKeys.all })
      // Anular restituye la línea: puede devolver un cupo de promo (1543-b4).
      void invalidarCuposPromo(queryClient)
    },
  })
}

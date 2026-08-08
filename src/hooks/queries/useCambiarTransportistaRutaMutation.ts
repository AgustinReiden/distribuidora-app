/**
 * Reasigna una ruta YA ARMADA a otro transportista (mig 172).
 *
 * Por qué hace falta un RPC y no un update: para `aplicar_orden_ruta` el
 * transportista es parte de la IDENTIDAD de la ruta —la busca por
 * (transportista_id, fecha, estado, sucursal_id)—, así que elegir otro chofer y
 * volver a armar no mueve la ruta, crea una segunda y deja la original viva con
 * sus pedidos en `asignado`. `cambiar_transportista_recorrido` mueve el
 * recorrido y el `transportista_id` de sus pedidos en una sola transacción,
 * conservando el orden de entrega y la optimización.
 *
 * Las guardas (permisos, sucursal, ruta en curso, sin entregas hechas, sin ruta
 * duplicada del destino) viven en la RPC: acá solo se traduce el error a algo
 * que se pueda mostrar en pantalla.
 */
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { pedidosKeys } from './usePedidosQuery'

export interface CambiarTransportistaRutaInput {
  recorridoId: string
  transportistaId: string
}

async function cambiarTransportistaRuta({
  recorridoId,
  transportistaId,
}: CambiarTransportistaRutaInput): Promise<string> {
  const { data, error } = await supabase.rpc('cambiar_transportista_recorrido', {
    p_recorrido_id: Number(recorridoId),
    p_transportista_id: transportistaId,
  })

  // Los RAISE EXCEPTION de la RPC ya vienen redactados para el usuario ("ya
  // tiene N entregas hechas", "ya tiene la ruta #X armada para el ..."), así
  // que se muestran tal cual en vez de taparlos con un mensaje genérico.
  if (error) throw new Error(error.message || 'No se pudo cambiar el transportista de la ruta')

  return String(data ?? recorridoId)
}

export function useCambiarTransportistaRutaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: cambiarTransportistaRuta,
    onSuccess: () => {
      // Los pedidos cambiaron de transportista_id (lo que ve la PWA del chofer).
      queryClient.invalidateQueries({ queryKey: pedidosKeys.all(currentSucursalId) })
      // La ruta ya no está bajo el chofer viejo y sí bajo el nuevo: las tres
      // queries se indexan por transportista, así que se invalidan por prefijo
      // (no alcanza con la del chofer actual del modal).
      queryClient.invalidateQueries({ queryKey: ['recorrido-existente'] })
      queryClient.invalidateQueries({ queryKey: ['rutas-en-curso'] })
      queryClient.invalidateQueries({ queryKey: ['recorrido-activo'] })
      // La hoja de ruta lleva el nombre del chofer impreso arriba.
      queryClient.invalidateQueries({ queryKey: ['recorridos-hoja-ruta'] })
    },
  })
}

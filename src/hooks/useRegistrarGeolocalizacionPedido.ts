import { useCallback } from 'react'
import { supabase } from './supabase/base'
import { logger } from '../utils/logger'
import { useGeolocationCapture, type GpsResult } from './useGeolocationCapture'

/**
 * Wraps `useGeolocationCapture` + el RPC `registrar_geolocalizacion_pedido`.
 *
 * Devuelve dos primitivas:
 * - `capturarGps()`: dispara la captura del navegador en cuanto el usuario
 *   confirma el pedido (en paralelo a la creación). Devuelve siempre una
 *   `Promise<GpsResult>` que nunca rechaza.
 * - `registrarGpsPedido(pedidoId, gps)`: persiste el resultado contra el RPC.
 *   No lanza; loguea errores silenciosamente.
 *
 * Diseño: el componente arranca `capturarGps()` en paralelo con la mutation
 * de creación; al volver la creación con un id válido, envía el GPS capturado
 * vía RPC. El usuario ve "Pedido creado" sin esperar el GPS, y el check-in
 * queda registrado a más tardar en `timeout` segundos.
 */
export function useRegistrarGeolocalizacionPedido() {
  const capturarGps = useGeolocationCapture()

  const registrarGpsPedido = useCallback(
    async (pedidoId: string | number, gps: GpsResult, motivoOmision?: string | null): Promise<void> => {
      try {
        const params: Record<string, unknown> = {
          p_pedido_id: typeof pedidoId === 'string' ? Number(pedidoId) : pedidoId,
          p_status: gps.status,
        }
        if (gps.status === 'ok') {
          params.p_lat = gps.lat
          params.p_lng = gps.lng
          params.p_accuracy = gps.accuracy
          params.p_capturado_at = gps.capturadoAt
        } else if (motivoOmision && motivoOmision.trim().length > 0) {
          params.p_motivo_omision = motivoOmision.trim()
        }
        const { error } = await supabase.rpc('registrar_geolocalizacion_pedido', params)
        if (error) {
          logger.warn('[registrar_geolocalizacion_pedido] RPC error:', error.message)
        }
      } catch (err) {
        logger.warn('[registrar_geolocalizacion_pedido] unexpected error:', (err as Error).message)
      }
    },
    [],
  )

  return { capturarGps, registrarGpsPedido }
}

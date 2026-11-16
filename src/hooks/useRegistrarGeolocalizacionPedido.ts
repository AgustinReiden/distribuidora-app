import { useCallback } from 'react'
import { supabase } from './supabase/base'
import { logger } from '../utils/logger'
import { useGeolocationCapture, type GpsResult } from './useGeolocationCapture'

/**
 * Llama una RPC de GPS con `p_diagnostico` (#1602, mig 507) y, si el servidor
 * todavía no tiene esa firma (PGRST202: la migración no está aplicada), repite
 * sin él: el diagnóstico es un extra y no puede costar la ubicación.
 */
export async function rpcGpsConDiagnostico<T = unknown>(
  nombre: string,
  params: Record<string, unknown>,
  opciones: { sucursalId?: number | null } = {},
): Promise<{ data: T | null; error: { code?: string; message: string } | null }> {
  const llamar = async (p: Record<string, unknown>) => {
    let b = supabase.rpc(nombre, p)
    // La sucursal en el request, no en el header global: el replay de la cola
    // registra el GPS con la sucursal en la que se encoló (INF-2, #1563).
    if (opciones.sucursalId != null) b = b.setHeader('X-Sucursal-ID', String(opciones.sucursalId))
    return (await b) as { data: T | null; error: { code?: string; message: string } | null }
  }
  const res = await llamar(params)
  if (res.error?.code === 'PGRST202' && 'p_diagnostico' in params) {
    const { p_diagnostico: _sinDiagnostico, ...sin } = params
    return llamar(sin)
  }
  return res
}

/**
 * Persiste un `GpsResult` contra `registrar_geolocalizacion_pedido`. No lanza;
 * loguea errores silenciosamente. Lo usan el alta online (vía el hook) y el
 * replay de la cola sin conexión (#1602), que le pasa la sucursal del pedido.
 */
export async function registrarGeolocalizacionPedido(
  pedidoId: string | number,
  gps: GpsResult,
  motivoOmision?: string | null,
  opciones: { sucursalId?: number | null } = {},
): Promise<void> {
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
    if (gps.diagnostico) params.p_diagnostico = gps.diagnostico
    const { error } = await rpcGpsConDiagnostico('registrar_geolocalizacion_pedido', params, opciones)
    if (error) {
      logger.warn('[registrar_geolocalizacion_pedido] RPC error:', error.message)
    }
  } catch (err) {
    logger.warn('[registrar_geolocalizacion_pedido] unexpected error:', (err as Error).message)
  }
}

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
    (pedidoId: string | number, gps: GpsResult, motivoOmision?: string | null): Promise<void> =>
      registrarGeolocalizacionPedido(pedidoId, gps, motivoOmision),
    [],
  )

  return { capturarGps, registrarGpsPedido }
}

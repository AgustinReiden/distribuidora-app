/**
 * El motivo de «ubicación bloqueada», una vez por día (decisión del dueño, 16/11).
 *
 * Con la ubicación bloqueada (`denied`) el motivo se pedía en cada pedido y en
 * cada visita, y es siempre el mismo: el teléfono sigue bloqueado. Se pide en el
 * primero del día y los demás lo reutilizan; cada pedido lo sigue guardando en
 * `gps_motivo_omision`. Sólo para `denied`: un timeout o un GPS sin señal son de
 * ese momento y se justifican cada vez.
 *
 * Vive en `localStorage`, por equipo, con el día argentino. Si no hay
 * almacenamiento, se vuelve a pedir: nunca se inventa un motivo.
 */
import { fechaLocalISO } from './formatters'
import type { GpsStatus } from '../hooks/useGeolocationCapture'

const CLAVE = 'gps.motivo_denied'

export function motivoSinGpsDeHoy(status: GpsStatus): string | null {
  if (status !== 'denied') return null
  try {
    const crudo = localStorage.getItem(CLAVE)
    if (!crudo) return null
    const { dia, motivo } = JSON.parse(crudo) as { dia?: unknown; motivo?: unknown }
    if (dia !== fechaLocalISO() || typeof motivo !== 'string') return null
    return motivo.trim().length > 0 ? motivo.trim() : null
  } catch {
    return null
  }
}

export function recordarMotivoSinGps(status: GpsStatus, motivo: string): void {
  if (status !== 'denied' || motivo.trim().length === 0) return
  try {
    localStorage.setItem(CLAVE, JSON.stringify({ dia: fechaLocalISO(), motivo: motivo.trim() }))
  } catch {
    // sin almacenamiento: mañana (y el próximo pedido) se vuelve a pedir
  }
}

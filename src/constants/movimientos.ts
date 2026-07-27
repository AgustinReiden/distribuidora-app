/**
 * Constantes compartidas de movimientos entre sucursales.
 *
 * El mapa de badges estaba duplicado literalmente en VistaMovimientos y
 * ModalDetalleMovimiento; vive acá para que agregar un estado sea un solo cambio.
 */
import type { EstadoMovimiento } from '../hooks/queries'

export const ESTADO_MOVIMIENTO_BADGE: Record<EstadoMovimiento, string> = {
  pendiente: 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400',
  aceptada: 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400',
  denegada: 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400',
  cancelada: 'bg-gray-100 text-gray-600 dark:bg-gray-700 dark:text-gray-300',
}

/** Cómo se lee la resolución en la línea de auditoría ("Aceptado el … por …"). */
export const VERBO_RESOLUCION: Record<EstadoMovimiento, string> = {
  pendiente: 'Resuelto',
  aceptada: 'Aceptado',
  denegada: 'Denegado',
  cancelada: 'Cancelado',
}

/** Horas transcurridas desde una fecha ISO (para marcar envíos demorados). */
export function horasDesde(iso: string | null | undefined): number {
  if (!iso) return 0
  const ms = Date.now() - new Date(iso).getTime()
  return ms > 0 ? Math.floor(ms / 3_600_000) : 0
}

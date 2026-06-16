/**
 * Utilidades de geolocalización.
 *
 * - `haversineMeters`: distancia en metros entre dos coordenadas (lat,lng).
 * - `formatDistancia`: formatea metros como "320 m" / "1.4 km" / "—".
 * - `clasificarDistancia`: semáforo del panel admin (ok / cerca / lejos / sin-dato).
 * - `colorPreventista`: paleta determinística por id (consistente entre mapa,
 *   sidebar y timeline).
 */

const EARTH_RADIUS_M = 6_371_000

/**
 * Umbral en metros para considerar que un pedido o visita fue hecho "lejos"
 * del cliente registrado. Usado tanto para el semáforo en frontend como
 * para el campo `pedidos_lejos` del RPC del panel admin (que tiene un
 * literal espejo en SQL — mantener en sync).
 */
export const ANOMALIA_DISTANCIA_METROS = 1000

const PALETA_PREVENTISTAS = [
  '#2563eb', // azul
  '#dc2626', // rojo
  '#16a34a', // verde
  '#ea580c', // naranja
  '#9333ea', // violeta
  '#0891b2', // cyan
  '#ca8a04', // amarillo oscuro
  '#db2777', // rosa
] as const

export type Coord = { lat: number; lng: number }

export function haversineMeters(a: Coord, b: Coord): number {
  const toRad = (deg: number) => (deg * Math.PI) / 180
  const dLat = toRad(b.lat - a.lat)
  const dLng = toRad(b.lng - a.lng)
  const lat1 = toRad(a.lat)
  const lat2 = toRad(b.lat)
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2
  return 2 * EARTH_RADIUS_M * Math.asin(Math.sqrt(h))
}

/**
 * Rumbo inicial (bearing) de `a` → `b`, en grados horarios desde el norte (0-360).
 * Se usa para orientar la cámara de navegación cuando el `heading` del GPS es
 * null/ruidoso (parado o a baja velocidad): se deriva del movimiento o del rumbo
 * de la ruta.
 */
export function computeBearing(a: Coord, b: Coord): number {
  const toRad = (deg: number) => (deg * Math.PI) / 180
  const lat1 = toRad(a.lat)
  const lat2 = toRad(b.lat)
  const dLng = toRad(b.lng - a.lng)
  const y = Math.sin(dLng) * Math.cos(lat2)
  const x = Math.cos(lat1) * Math.sin(lat2) - Math.sin(lat1) * Math.cos(lat2) * Math.cos(dLng)
  return (Math.atan2(y, x) * 180 / Math.PI + 360) % 360
}

export function formatDistancia(metros: number | null | undefined): string {
  if (metros == null || !Number.isFinite(metros)) return '—'
  if (metros < 1000) return `${Math.round(metros)} m`
  return `${(metros / 1000).toFixed(1)} km`
}

export type ClasificacionDistancia = 'ok' | 'cerca' | 'lejos' | 'sin_dato'

export function clasificarDistancia(metros: number | null | undefined): ClasificacionDistancia {
  if (metros == null || !Number.isFinite(metros)) return 'sin_dato'
  if (metros < 500) return 'ok'
  if (metros < ANOMALIA_DISTANCIA_METROS) return 'cerca'
  return 'lejos'
}

export const SEMAFORO_COLORS: Record<ClasificacionDistancia, { bg: string; text: string; label: string }> = {
  ok:       { bg: 'bg-green-100 text-green-800',   text: 'text-green-700',   label: 'En el cliente' },
  cerca:    { bg: 'bg-yellow-100 text-yellow-800', text: 'text-yellow-700',  label: 'Cerca del cliente' },
  lejos:    { bg: 'bg-red-100 text-red-800',       text: 'text-red-700',     label: 'Lejos del cliente' },
  sin_dato: { bg: 'bg-gray-100 text-gray-600',     text: 'text-gray-500',    label: 'Sin ubicación' },
}

/**
 * Devuelve un color consistente de la paleta para un preventista dado.
 * El mismo preventista_id siempre obtiene el mismo color en sidebar, pin y timeline.
 */
export function colorPreventista(preventistaId: string): string {
  let hash = 0
  for (let i = 0; i < preventistaId.length; i++) {
    hash = (hash * 31 + preventistaId.charCodeAt(i)) | 0
  }
  const idx = Math.abs(hash) % PALETA_PREVENTISTAS.length
  return PALETA_PREVENTISTAS[idx]
}

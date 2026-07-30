/**
 * Control de cordura de la dirección contra la zona del cliente.
 *
 * El caso real: "Chacabuco 543" existe en Banda del Río Salí y "Batalla de
 * Chacabuco 543" en San Miguel de Tucumán. Google elige una y nadie se entera
 * hasta que el chofer llega a 12 km del cliente. No se puede resolver la
 * ambigüedad automáticamente —las dos direcciones existen—, pero sí se puede
 * comparar el punto elegido contra dónde están los demás clientes de la misma
 * zona, que es información que el sistema ya tiene.
 *
 * Es una advertencia, nunca un bloqueo: una zona puede tener clientes
 * legítimamente dispersos, y una zona nueva con dos clientes no dice nada.
 */
import { haversineMeters, type Coord } from './geo'

/**
 * A partir de esta distancia al centroide de su zona, la dirección se marca
 * como sospechosa. 8 km es holgado para un reparto urbano (las zonas son
 * barrios) y sigue atrapando el error típico, que es caer en otra localidad.
 */
export const UMBRAL_LEJOS_DE_ZONA_METROS = 8000

/** Con menos clientes ubicados que esto, el centroide no es representativo. */
export const MIN_CLIENTES_PARA_CENTROIDE = 3

export interface ClienteUbicado {
  id: string | number
  zona_id?: string | number | null
  latitud?: number | null
  longitud?: number | null
}

export interface ChequeoZona {
  /** null = no se pudo evaluar (sin zona, sin coords, o muestra insuficiente). */
  distanciaMetros: number | null
  lejos: boolean
  /** Cuántos clientes de la zona se usaron para el centroide. */
  muestra: number
}

/**
 * Centroide aritmético de los clientes ubicados de una zona.
 *
 * El promedio simple alcanza: a escala de una ciudad la curvatura de la Tierra
 * no mueve la aguja frente a un umbral de kilómetros, y una media geodésica
 * sería precisión falsa sobre datos cargados a mano.
 */
export function centroideZona(
  clientes: ClienteUbicado[],
  zonaId: string | number,
  excluirClienteId?: string | number | null,
): { centro: Coord; muestra: number } | null {
  const zona = String(zonaId)
  const puntos = clientes.filter(c =>
    String(c.zona_id ?? '') === zona &&
    (excluirClienteId == null || String(c.id) !== String(excluirClienteId)) &&
    Number.isFinite(Number(c.latitud)) &&
    Number.isFinite(Number(c.longitud)) &&
    Number(c.latitud) !== 0 &&
    Number(c.longitud) !== 0,
  )

  if (puntos.length < MIN_CLIENTES_PARA_CENTROIDE) return null

  let lat = 0
  let lng = 0
  for (const p of puntos) {
    lat += Number(p.latitud)
    lng += Number(p.longitud)
  }
  return { centro: { lat: lat / puntos.length, lng: lng / puntos.length }, muestra: puntos.length }
}

/** Qué tan lejos cae una coordenada del centroide de su zona. */
export function chequearCoordenadaEnZona(
  coord: { latitud?: number | null; longitud?: number | null },
  clientes: ClienteUbicado[],
  zonaId: string | number | null | undefined,
  excluirClienteId?: string | number | null,
): ChequeoZona {
  const sinDato: ChequeoZona = { distanciaMetros: null, lejos: false, muestra: 0 }

  const lat = Number(coord.latitud)
  const lng = Number(coord.longitud)
  if (!zonaId || !Number.isFinite(lat) || !Number.isFinite(lng) || lat === 0 || lng === 0) {
    return sinDato
  }

  const centroide = centroideZona(clientes, zonaId, excluirClienteId)
  if (!centroide) return sinDato

  const distancia = haversineMeters({ lat, lng }, centroide.centro)
  return {
    distanciaMetros: distancia,
    lejos: distancia > UMBRAL_LEJOS_DE_ZONA_METROS,
    muestra: centroide.muestra,
  }
}

/**
 * navSnap — proyección de la posición GPS sobre la polyline del tramo de
 * navegación (snap-to-route). Permite:
 *  - distancia A LO LARGO de la ruta hasta la próxima maniobra (en vez de la
 *    distancia recta, que en calles sinuosas miente),
 *  - avance de maniobra por posición sobre la ruta,
 *  - detección de desvío (distancia perpendicular a la ruta).
 *
 * Pensado para correr en cada tick de GPS sin costo creciente: las distancias
 * acumuladas se precalculan una vez por tramo (`construirSnapper`) y la búsqueda
 * se acota a una ventana de ±VENTANA segmentos alrededor del último índice.
 */
import { haversineMeters, type Coord } from './geo';
import type { LatLngTuple } from './polyline';

const R = 6_371_000;
const rad = (d: number): number => (d * Math.PI) / 180;

export interface Snapper {
  puntos: LatLngTuple[];
  /** Distancia acumulada (m) desde el inicio en cada vértice (len = puntos.length). */
  cumdist: number[];
}

export interface PuntoSnap {
  /** Punto proyectado sobre la ruta [lat, lng]. */
  snapped: LatLngTuple;
  /** Índice del segmento [i, i+1] sobre el que cayó la proyección. */
  segmentIndex: number;
  /** Distancia (m) a lo largo de la ruta hasta el punto proyectado. */
  distanciaEnRuta: number;
  /** Distancia perpendicular (m) de la posición a la ruta (mide el desvío). */
  perpendicularM: number;
}

/** Segmentos a cada lado del último índice que se buscan por tick (O(constante)). */
const VENTANA = 50;

/** Precalcula las distancias acumuladas del tramo (una vez por tramo). */
export function construirSnapper(puntos: LatLngTuple[]): Snapper {
  const cumdist = new Array<number>(puntos.length).fill(0);
  for (let i = 1; i < puntos.length; i++) {
    const a = puntos[i - 1];
    const b = puntos[i];
    cumdist[i] = cumdist[i - 1] + haversineMeters({ lat: a[0], lng: a[1] }, { lat: b[0], lng: b[1] });
  }
  return { puntos, cumdist };
}

/**
 * Proyecta `pos` sobre la ruta. `hint` = último segmentIndex conocido (acota la
 * búsqueda). `ventana` = Infinity hace búsqueda completa (para mapear un punto
 * fijo, p. ej. una maniobra, a su distancia en ruta — ver `distanciaEnRutaDe`).
 */
export function snapEnRuta(
  snapper: Snapper,
  pos: Coord,
  hint = 0,
  ventana: number = VENTANA,
): PuntoSnap {
  const { puntos, cumdist } = snapper;
  if (puntos.length < 2) {
    return {
      snapped: puntos[0] ?? [pos.lat, pos.lng],
      segmentIndex: 0,
      distanciaEnRuta: 0,
      perpendicularM: 0,
    };
  }

  const desde = Math.max(0, Math.floor(hint - ventana));
  const hasta = Math.min(puntos.length - 2, Math.ceil(hint + ventana));
  // Plano equirectangular local centrado en la latitud de la posición (rápido).
  const cos = Math.cos(rad(pos.lat));
  const px = rad(pos.lng) * cos * R;
  const py = rad(pos.lat) * R;

  let mejor: PuntoSnap | null = null;
  let mejorPerp = Infinity;

  for (let i = desde; i <= hasta; i++) {
    const a = puntos[i];
    const b = puntos[i + 1];
    const ax = rad(a[1]) * cos * R;
    const ay = rad(a[0]) * R;
    const bx = rad(b[1]) * cos * R;
    const by = rad(b[0]) * R;
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    const t = len2 > 0 ? Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / len2)) : 0;
    const qx = ax + t * dx;
    const qy = ay + t * dy;
    const perp = Math.hypot(px - qx, py - qy);
    if (perp < mejorPerp) {
      mejorPerp = perp;
      const segLen = cumdist[i + 1] - cumdist[i];
      mejor = {
        snapped: [a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])],
        segmentIndex: i,
        distanciaEnRuta: cumdist[i] + t * segLen,
        perpendicularM: perp,
      };
    }
  }
  // `mejor` nunca es null acá (puntos.length >= 2 → al menos un segmento).
  return mejor as PuntoSnap;
}

/** Distancia en ruta de un punto fijo (p. ej. el inicio de una maniobra). */
export function distanciaEnRutaDe(snapper: Snapper, punto: Coord): number {
  return snapEnRuta(snapper, punto, 0, Number.POSITIVE_INFINITY).distanciaEnRuta;
}

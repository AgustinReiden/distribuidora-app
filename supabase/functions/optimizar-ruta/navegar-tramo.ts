// Navegación asistida de UN tramo (posición actual → próxima parada) para el
// turn-by-turn in-app del transportista. A diferencia del optimizador (que da
// el ORDEN global de las paradas), acá pedimos a Routes API computeRoutes los
// PASOS con maniobras (`navigationInstruction`) y la geometría por paso, para
// guiar al chofer giro a giro dentro de la app.
//
// Costo: un solo origen → un destino, sin intermedios, `TRAFFIC_UNAWARE` →
// queda en el tier Essentials de Routes API (pedir steps/navigationInstruction
// NO sube de tier; lo que sube es el tráfico o >10 waypoints). languageCode
// es-419 para que las instrucciones vengan en castellano.
//
// Separado de index.ts para poder testear el parseo sin red.

import type { LatLng } from "./tramos.ts";

export interface PasoNavegacion {
  /** Enum de maniobra de Google (TURN_RIGHT, ROUNDABOUT_LEFT, …) o "". */
  maniobra: string;
  /** Texto de la instrucción ya localizado (es-419). */
  instruccion: string;
  distancia_metros: number;
  duracion_segundos: number;
  /** Geometría del paso (encoded polyline, precisión 5). */
  polyline: string;
  /** Punto donde ocurre la maniobra (startLocation del paso). */
  inicio: { lat: number; lng: number };
  /** Fin del paso (endLocation). */
  fin: { lat: number; lng: number };
}

export interface TramoNavegacion {
  pasos: PasoNavegacion[];
  /** Geometría completa del tramo (encoded polyline) para dibujar la ruta. */
  polyline: string;
  distancia_metros: number;
  duracion_segundos: number;
}

// --- Subconjunto tipado de la respuesta de computeRoutes que consumimos ---
interface RoutesLatLng {
  latLng?: { latitude?: number; longitude?: number };
}
interface RoutesStep {
  navigationInstruction?: { maneuver?: string; instructions?: string };
  distanceMeters?: number;
  staticDuration?: string;
  polyline?: { encodedPolyline?: string };
  startLocation?: RoutesLatLng;
  endLocation?: RoutesLatLng;
}
interface RoutesLeg {
  steps?: RoutesStep[];
}
interface RoutesRoute {
  distanceMeters?: number;
  duration?: string;
  polyline?: { encodedPolyline?: string };
  legs?: RoutesLeg[];
}
export interface RoutesResponse {
  routes?: RoutesRoute[];
  error?: { message?: string };
}

/** FieldMask: pasos con maniobra + geometría + totales del tramo. */
const NAV_FIELD_MASK = [
  "routes.legs.steps.navigationInstruction",
  "routes.legs.steps.distanceMeters",
  "routes.legs.steps.staticDuration",
  "routes.legs.steps.polyline.encodedPolyline",
  "routes.legs.steps.startLocation",
  "routes.legs.steps.endLocation",
  "routes.polyline.encodedPolyline",
  "routes.duration",
  "routes.distanceMeters",
].join(",");

const seg = (s: string | undefined): number =>
  parseInt(String(s ?? "0s").replace("s", "")) || 0;

const coord = (loc: RoutesLatLng | undefined): { lat: number; lng: number } => ({
  lat: loc?.latLng?.latitude ?? 0,
  lng: loc?.latLng?.longitude ?? 0,
});

/** Transforma la respuesta de computeRoutes en el tramo que consume el front. */
export function parseNavTramo(data: RoutesResponse): TramoNavegacion {
  const route = data.routes?.[0];
  if (!route) {
    throw new Error("Google Routes no devolvió una ruta para el tramo");
  }
  const pasos: PasoNavegacion[] = (route.legs ?? [])
    .flatMap((leg) => leg.steps ?? [])
    .map((s) => ({
      maniobra: s.navigationInstruction?.maneuver ?? "",
      instruccion: s.navigationInstruction?.instructions ?? "",
      distancia_metros: s.distanceMeters ?? 0,
      duracion_segundos: seg(s.staticDuration),
      polyline: s.polyline?.encodedPolyline ?? "",
      inicio: coord(s.startLocation),
      fin: coord(s.endLocation),
    }));

  return {
    pasos,
    polyline: route.polyline?.encodedPolyline ?? "",
    distancia_metros: route.distanceMeters ?? 0,
    duracion_segundos: seg(route.duration),
  };
}

/** Pide a Routes API el tramo navegable origen → destino (sin intermedios). */
export async function navegarTramo(
  apiKey: string,
  origen: LatLng,
  destino: LatLng,
): Promise<TramoNavegacion> {
  const res = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": apiKey,
      "X-Goog-FieldMask": NAV_FIELD_MASK,
    },
    body: JSON.stringify({
      origin: { location: { latLng: origen } },
      destination: { location: { latLng: destino } },
      travelMode: "DRIVE",
      // Sin tráfico a propósito: tramos cortos urbanos + queda en Essentials.
      routingPreference: "TRAFFIC_UNAWARE",
      polylineEncoding: "ENCODED_POLYLINE",
      languageCode: "es-419",
      units: "METRIC",
    }),
  });

  const data = (await res.json()) as RoutesResponse;
  if (data.error) {
    throw new Error(data.error.message ?? `Google Routes API HTTP ${res.status}`);
  }
  return parseNavTramo(data);
}

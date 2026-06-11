// Edge Function: optimizar-ruta
//
// Optimiza el orden de entrega de los pedidos de un transportista usando
// Google Routes API (computeRoutes + optimizeWaypointOrder). Reemplaza al
// webhook de n8n "Optimizar Ruta Transportista":
//   * la API key de Google vive como secret del servidor (GOOGLE_API_KEY),
//     no en el bundle del frontend;
//   * la plataforma exige JWT válido (verify_jwt=true) → solo usuarios
//     logueados de la app pueden invocarla;
//   * soporta más de 25 pedidos partiendo en tramos encadenados (ver tramos.ts).
//
// Request (POST, mismo shape que el webhook legacy, sin google_api_key):
//   { deposito_lat, deposito_lng, pedidos: [{ pedido_id, cliente_nombre,
//     direccion, latitud, longitud }] }
//
// Response: mismo shape que el workflow n8n (success, orden_optimizado,
// distancia_total, duracion_total, *_formato, mensaje/error) para que el
// frontend no necesite cambios de parsing.
//
// Variables de entorno:
//   - GOOGLE_API_KEY (secret) — key de Google Maps Platform con Routes API

import { serve } from "std/http/server.ts";
import {
  type GoogleRoute,
  type LatLng,
  partirEnTramos,
  type PedidoRuta,
  unirTramos,
} from "./tramos.ts";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-sucursal-id",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface RequestBody {
  deposito_lat?: number;
  deposito_lng?: number;
  pedidos?: Array<Partial<PedidoRuta> & { latitud?: number | null; longitud?: number | null }>;
}

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

async function llamarGoogle(
  apiKey: string,
  origen: LatLng,
  destino: LatLng,
  intermedios: PedidoRuta[],
): Promise<GoogleRoute> {
  const res = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": apiKey,
      "X-Goog-FieldMask":
        "routes.duration,routes.distanceMeters,routes.optimizedIntermediateWaypointIndex,routes.legs",
    },
    body: JSON.stringify({
      origin: { location: { latLng: origen } },
      destination: { location: { latLng: destino } },
      intermediates: intermedios.map((p) => ({
        location: { latLng: { latitude: p.latitud, longitude: p.longitud } },
      })),
      travelMode: "DRIVE",
      optimizeWaypointOrder: intermedios.length > 1,
      routingPreference: "TRAFFIC_AWARE",
      languageCode: "es-419",
      units: "METRIC",
    }),
  });

  const data = await res.json();
  if (data.error) {
    throw new Error(data.error.message ?? `Google Routes API HTTP ${res.status}`);
  }
  const route = data.routes?.[0];
  if (!route) {
    throw new Error("Google Routes no pudo calcular una ruta válida entre los puntos");
  }
  return route as GoogleRoute;
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return jsonResponse({ success: false, error: "Método no permitido" }, 405);
  }

  const apiKey = Deno.env.get("GOOGLE_API_KEY") ?? "";
  if (!apiKey) {
    console.error("[optimizar-ruta] GOOGLE_API_KEY secret no configurado");
    return jsonResponse({
      success: false,
      error: "GOOGLE_API_KEY no configurada",
      mensaje: "Falta configurar el secret GOOGLE_API_KEY en Supabase Edge Functions",
    });
  }

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ success: false, error: "Body inválido", mensaje: "Se esperaba JSON" });
  }

  const pedidos = body.pedidos ?? [];
  if (pedidos.length === 0) {
    return jsonResponse({
      success: false,
      error: "No hay pedidos para optimizar",
      mensaje: "Debe haber al menos un pedido asignado al transportista",
    });
  }

  const deposito: LatLng = {
    latitude: body.deposito_lat ?? -26.8241,
    longitude: body.deposito_lng ?? -65.2226,
  };

  const conCoords: PedidoRuta[] = [];
  const sinCoords: typeof pedidos = [];
  for (const p of pedidos) {
    if (p.latitud != null && p.longitud != null && p.pedido_id != null) {
      conCoords.push(p as PedidoRuta);
    } else {
      sinCoords.push(p);
    }
  }

  if (conCoords.length === 0) {
    return jsonResponse({
      success: false,
      error: "Ningún pedido tiene coordenadas",
      mensaje: "Los clientes deben tener latitud y longitud para optimizar la ruta",
      pedidos_sin_coordenadas: sinCoords.length,
    });
  }

  const tramos = partirEnTramos(deposito, conCoords);

  let rutas: GoogleRoute[];
  try {
    // Secuencial a propósito: son 1-3 requests y simplifica el rate limiting.
    rutas = [];
    for (const tramo of tramos) {
      rutas.push(await llamarGoogle(apiKey, tramo.origen, tramo.destino, tramo.intermedios));
    }
  } catch (err) {
    console.error("[optimizar-ruta] Google error:", err);
    return jsonResponse({
      success: false,
      error: "Error de Google Routes API",
      mensaje: err instanceof Error ? err.message : "No se pudo calcular la ruta",
    });
  }

  const { ordenOptimizado, distanciaTotalMetros, duracionTotalSegundos } = unirTramos(
    tramos,
    rutas,
  );

  // Pedidos sin coordenadas: al final de la lista, marcados.
  for (const p of sinCoords) {
    ordenOptimizado.push({
      pedido_id: String(p.pedido_id ?? ""),
      orden: ordenOptimizado.length + 1,
      cliente: p.cliente_nombre ?? p.nombre_fantasia ?? "Sin nombre",
      direccion: p.direccion ?? "",
      sin_coordenadas: true,
    });
  }

  const distanciaTotalKm = Math.round(distanciaTotalMetros / 10) / 100;
  const duracionTotalMinutos = Math.round(duracionTotalSegundos / 60);
  const horas = Math.floor(duracionTotalMinutos / 60);
  const minutos = duracionTotalMinutos % 60;

  return jsonResponse({
    success: true,
    optimizado_por: tramos.length > 1
      ? `Google Routes API (${tramos.length} tramos)`
      : "Google Routes API",
    total_pedidos: ordenOptimizado.length,
    pedidos_con_coordenadas: conCoords.length,
    pedidos_sin_coordenadas: sinCoords.length,
    distancia_total_km: distanciaTotalKm,
    distancia_total: distanciaTotalMetros,
    duracion_total: duracionTotalSegundos,
    duracion_total_minutos: duracionTotalMinutos,
    duracion_formato: horas > 0 ? `${horas}h ${minutos}m` : `${minutos} minutos`,
    distancia_formato: `${distanciaTotalKm} km`,
    orden_optimizado: ordenOptimizado,
  });
});

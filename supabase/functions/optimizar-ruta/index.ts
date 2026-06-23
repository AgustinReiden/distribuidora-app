// Edge Function: optimizar-ruta
//
// Optimiza el orden de entrega de los pedidos de un transportista. Dos motores:
//   1) Google Route Optimization API (optimizeTours) si está el secret
//      GOOGLE_SA_KEY → óptimo global de 100+ paradas en una llamada (ideal 40+).
//   2) Fallback: Google Routes API computeRoutes (GOOGLE_API_KEY), partiendo en
//      tramos de ≤23 (ver tramos.ts) — para no romper si el SA no está cargado.
//
// Request (POST): { deposito_lat, deposito_lng, pedidos: [{ pedido_id,
//   cliente_nombre, direccion, latitud, longitud }] }
// Response: { success, orden_optimizado[], polylines[], distancia_total,
//   duracion_total, *_formato, mensaje/error }
//
// Variables de entorno:
//   - GOOGLE_SA_KEY  (secret) — JSON del service account (Route Optimization)
//   - GOOGLE_API_KEY (secret) — key de Maps Platform (fallback computeRoutes)

import { serve } from "std/http/server.ts";
import {
  type GoogleRoute,
  type LatLng,
  partirEnTramos,
  type PedidoRuta,
  type RutaUnida,
  unirTramos,
} from "./tramos.ts";
import {
  optimizeTours,
  optimizeToursMulti,
  type RepartidorVehiculo,
  type PedidoRutaZona,
} from "./route-optimization.ts";
import { navegarTramo } from "./navegar-tramo.ts";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-sucursal-id",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface RequestBody {
  /** "navegar_tramo" → guía giro-a-giro de un tramo; ausente → optimizar ruta. */
  mode?: string;
  /** Modo navegar_tramo: origen (posición actual) y destino (próxima parada). */
  origen?: { lat?: number | null; lng?: number | null };
  destino?: { lat?: number | null; lng?: number | null };
  deposito_lat?: number;
  deposito_lng?: number;
  /** Punto de llegada para optimizar (opcional; si falta, fin = depósito). */
  destino_lat?: number | null;
  destino_lng?: number | null;
  pedidos?: Array<Partial<PedidoRuta> & { latitud?: number | null; longitud?: number | null; zona_id?: number | null }>;
  /** Ancla temporal para respetar ventanas horarias (solo optimizeTours). */
  fecha?: string; // "YYYY-MM-DD"
  hora_inicio?: string; // "HH:MM"
  /** Ventanas de entrega por pedido (derivadas de cliente.horario_entrega). */
  ventanas?: Array<{ pedido_id: string | number; inicio: string; fin: string }>;
  /** Split multi-repartidor: si viene (≥1), divide la ruta en N recorridos. */
  repartidores?: Array<{ transportista_id: string; max_paradas?: number | null; zonas_preferidas?: number[] | null }>;
}

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

// --- Fallback: computeRoutes (Routes API) con tramos de ≤23 ---
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
        "routes.duration,routes.distanceMeters,routes.optimizedIntermediateWaypointIndex,routes.legs,routes.polyline.encodedPolyline",
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
      polylineEncoding: "ENCODED_POLYLINE",
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

async function viaComputeRoutes(
  apiKey: string,
  deposito: LatLng,
  conCoords: PedidoRuta[],
  destino: LatLng = deposito,
): Promise<{ ruta: RutaUnida; tramos: number }> {
  const tramos = partirEnTramos(deposito, conCoords, destino);
  const rutas: GoogleRoute[] = [];
  // Secuencial a propósito: son 1-3 requests y simplifica el rate limiting.
  for (const tramo of tramos) {
    rutas.push(await llamarGoogle(apiKey, tramo.origen, tramo.destino, tramo.intermedios));
  }
  return { ruta: unirTramos(tramos, rutas), tramos: tramos.length };
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return jsonResponse({ success: false, error: "Método no permitido" }, 405);
  }

  const saKey = Deno.env.get("GOOGLE_SA_KEY") ?? "";
  const apiKey = Deno.env.get("GOOGLE_API_KEY") ?? "";
  if (!saKey && !apiKey) {
    console.error("[optimizar-ruta] Sin GOOGLE_SA_KEY ni GOOGLE_API_KEY");
    return jsonResponse({
      success: false,
      error: "Optimización no configurada",
      mensaje: "Falta configurar GOOGLE_SA_KEY (Route Optimization) o GOOGLE_API_KEY (Routes)",
    });
  }

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ success: false, error: "Body inválido", mensaje: "Se esperaba JSON" });
  }

  // --- Modo navegación asistida: guía giro-a-giro de un solo tramo ---
  if (body.mode === "navegar_tramo") {
    if (!apiKey) {
      return jsonResponse({
        success: false,
        error: "Navegación no configurada",
        mensaje: "Falta GOOGLE_API_KEY (Routes API) para la navegación in-app",
      });
    }
    const o = body.origen;
    const d = body.destino;
    if (o?.lat == null || o?.lng == null || d?.lat == null || d?.lng == null) {
      return jsonResponse({
        success: false,
        error: "Faltan coordenadas",
        mensaje: "Se requieren origen y destino con lat/lng para navegar el tramo",
      });
    }
    try {
      const tramo = await navegarTramo(
        apiKey,
        { latitude: o.lat, longitude: o.lng },
        { latitude: d.lat, longitude: d.lng },
      );
      return jsonResponse({ success: true, ...tramo });
    } catch (err) {
      console.error("[optimizar-ruta] navegar_tramo error:", err);
      return jsonResponse({
        success: false,
        error: "No se pudo calcular el tramo de navegación",
        mensaje: err instanceof Error ? err.message : "Error al calcular la ruta",
      });
    }
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
  // Punto de llegada opcional: si no viene, la ruta termina en el depósito.
  const destino: LatLng = (body.destino_lat != null && body.destino_lng != null)
    ? { latitude: body.destino_lat, longitude: body.destino_lng }
    : deposito;

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

  // --- Split multi-repartidor: N vehículos en una sola optimización ---
  // Requiere el motor optimizeTours (SA key); el fallback computeRoutes no
  // soporta múltiples vehículos. Los pedidos sin coordenadas los reparte el
  // front entre los choferes (no entran al optimizador).
  const repartidores = body.repartidores ?? [];
  if (repartidores.length > 0) {
    if (!saKey) {
      return jsonResponse({
        success: false,
        error: "Split no configurado",
        mensaje: "Dividir la ruta entre repartidores requiere GOOGLE_SA_KEY (Route Optimization).",
      });
    }
    try {
      const result = await optimizeToursMulti(
        saKey,
        deposito,
        conCoords as PedidoRutaZona[],
        destino,
        { fecha: body.fecha, horaInicio: body.hora_inicio, ventanas: body.ventanas },
        repartidores as RepartidorVehiculo[],
      );
      const recorridos = result.recorridos.map((r) => {
        const km = Math.round(r.distanciaTotalMetros / 10) / 100;
        const min = Math.round(r.duracionTotalSegundos / 60);
        const h = Math.floor(min / 60);
        const m = min % 60;
        return {
          transportista_id: r.transportista_id,
          total_pedidos: r.ordenOptimizado.length,
          orden_optimizado: r.ordenOptimizado,
          polylines: r.polylines,
          distancia_total: r.distanciaTotalMetros,
          distancia_total_km: km,
          duracion_total: r.duracionTotalSegundos,
          duracion_total_minutos: min,
          duracion_formato: h > 0 ? `${h}h ${m}m` : `${m} minutos`,
          distancia_formato: `${km} km`,
        };
      });
      return jsonResponse({
        success: true,
        optimizado_por: `Google Route Optimization (${repartidores.length} vehículos)`,
        recorridos,
        pedidos_sin_coordenadas: sinCoords.length,
        pedidos_sin_coordenadas_ids: sinCoords.map((p) => String(p.pedido_id ?? "")),
        skipped: result.skipped,
      });
    } catch (err) {
      console.error("[optimizar-ruta] split multi error:", err);
      return jsonResponse({
        success: false,
        error: "Error al dividir la ruta",
        mensaje: err instanceof Error ? err.message : "No se pudo optimizar el split",
      });
    }
  }

  // Ventanas horarias: solo las respeta optimizeTours (el fallback computeRoutes
  // no soporta time windows). ventanas_aplicadas avisa al front si se respetaron.
  const tieneVentanas = !!(body.fecha && body.hora_inicio && body.ventanas && body.ventanas.length > 0);
  let ventanasAplicadas = false;

  // Motor de optimización: Route Optimization (SA) con fallback a computeRoutes.
  let ruta: RutaUnida;
  let optimizadoPor: string;
  try {
    if (saKey) {
      try {
        ruta = await optimizeTours(saKey, deposito, conCoords, destino, {
          fecha: body.fecha,
          horaInicio: body.hora_inicio,
          ventanas: body.ventanas,
        });
        optimizadoPor = "Google Route Optimization";
        ventanasAplicadas = tieneVentanas;
      } catch (err) {
        if (!apiKey) throw err;
        console.error("[optimizar-ruta] Route Optimization falló, usando computeRoutes:", err);
        const r = await viaComputeRoutes(apiKey, deposito, conCoords, destino);
        ruta = r.ruta;
        optimizadoPor = `Google Routes API (${r.tramos} tramos, fallback)`;
      }
    } else {
      const r = await viaComputeRoutes(apiKey, deposito, conCoords, destino);
      ruta = r.ruta;
      optimizadoPor = r.tramos > 1 ? `Google Routes API (${r.tramos} tramos)` : "Google Routes API";
    }
  } catch (err) {
    console.error("[optimizar-ruta] Error de optimización:", err);
    return jsonResponse({
      success: false,
      error: "Error al optimizar la ruta",
      mensaje: err instanceof Error ? err.message : "No se pudo calcular la ruta",
    });
  }

  const { ordenOptimizado, distanciaTotalMetros, duracionTotalSegundos, polylines } = ruta;

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
    optimizado_por: optimizadoPor,
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
    polylines,
    ventanas_aplicadas: ventanasAplicadas,
  });
});

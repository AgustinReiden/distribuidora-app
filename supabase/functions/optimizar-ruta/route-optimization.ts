// Optimización de ruta con Google Route Optimization API (optimizeTours).
//
// A diferencia de computeRoutes (que parte en tramos de ≤25 y produce zigzag
// por barrido angular), optimizeTours resuelve el TSP global de 100+ paradas en
// una sola llamada → óptimo real para rutas de 40+ pedidos. Devuelve el mismo
// RutaUnida que tramos.ts para encajar sin cambios en index.ts.

import type { LatLng, OrdenOptimizadoItem, PedidoRuta, RutaUnida } from "./tramos.ts";
import { getAccessToken, type ServiceAccountKey } from "./sa-auth.ts";

interface OptimizeToursVisit {
  shipmentLabel?: string;
  shipmentIndex?: number;
  isPickup?: boolean;
}
interface OptimizeToursRoute {
  visits?: OptimizeToursVisit[];
  routePolyline?: { points?: string };
  metrics?: { travelDistanceMeters?: number; totalDuration?: string };
}
export interface OptimizeToursResponse {
  routes?: OptimizeToursRoute[];
  error?: { message?: string; code?: number; status?: string };
}

const parseDuracion = (s: string | undefined): number =>
  parseInt(String(s ?? "0s").replace("s", "")) || 0;

/**
 * Mapea la respuesta de optimizeTours a RutaUnida. El orden óptimo son los
 * `visits` (cada uno con `shipmentLabel` = pedido_id); la geometría es la
 * `routePolyline` única del vehículo. Pura/testeable.
 */
export function parseOptimizeTours(data: OptimizeToursResponse, pedidos: PedidoRuta[]): RutaUnida {
  const route = data.routes?.[0];
  if (!route) throw new Error("Route Optimization no devolvió ninguna ruta");

  const byLabel = new Map(pedidos.map((p) => [String(p.pedido_id), p]));
  const ordenOptimizado: OrdenOptimizadoItem[] = [];

  for (const v of route.visits ?? []) {
    if (v.shipmentLabel == null) continue;
    const p = byLabel.get(String(v.shipmentLabel));
    if (!p) continue;
    ordenOptimizado.push({
      pedido_id: p.pedido_id,
      orden: ordenOptimizado.length + 1,
      cliente: p.cliente_nombre ?? p.nombre_fantasia ?? "Sin nombre",
      direccion: p.direccion ?? "",
    });
  }

  const distanciaTotalMetros = route.metrics?.travelDistanceMeters ?? 0;
  const duracionTotalSegundos = parseDuracion(route.metrics?.totalDuration);
  const polylines = route.routePolyline?.points ? [route.routePolyline.points] : [];

  return { ordenOptimizado, distanciaTotalMetros, duracionTotalSegundos, polylines };
}

/**
 * Llama a optimizeTours: 1 shipment por pedido (delivery en la ubicación del
 * cliente, label = pedido_id), 1 vehículo con start/end en el depósito.
 */
export async function optimizeTours(
  saKeyJson: string,
  deposito: LatLng,
  pedidos: PedidoRuta[],
): Promise<RutaUnida> {
  const sa = JSON.parse(saKeyJson) as ServiceAccountKey;
  const token = await getAccessToken(sa);

  const body = {
    model: {
      shipments: pedidos.map((p) => ({
        label: String(p.pedido_id),
        deliveries: [{ arrivalLocation: { latitude: p.latitud, longitude: p.longitud } }],
      })),
      vehicles: [{
        startLocation: { latitude: deposito.latitude, longitude: deposito.longitude },
        endLocation: { latitude: deposito.latitude, longitude: deposito.longitude },
      }],
    },
    // Sin considerRoadTraffic: exige global_start_time y la ruta se arma el día
    // anterior, así que el tráfico "de ahora" no representa el de la entrega.
    populatePolylines: true,
  };

  const res = await fetch(
    `https://routeoptimization.googleapis.com/v1/projects/${sa.project_id}:optimizeTours`,
    {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    },
  );
  const data = (await res.json()) as OptimizeToursResponse;
  if (data.error) {
    throw new Error(data.error.message ?? `Route Optimization HTTP ${res.status}`);
  }
  return parseOptimizeTours(data, pedidos);
}

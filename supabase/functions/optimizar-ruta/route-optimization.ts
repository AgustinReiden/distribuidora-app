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

// === Ventanas horarias ===
// Argentina no tiene DST → offset fijo -03:00. El día anterior se arma la ruta,
// así que NO usamos considerRoadTraffic (sería tráfico de "ahora", no del día).
const TZ = "-03:00";
const SERVICE_SECONDS = 480; // ~8 min por parada: timing realista para las ventanas
const COST_LATE_PER_HOUR = 1000; // penalización ALTA por llegar tarde → prioriza la ventana
const COST_EARLY_PER_HOUR = 1; // leve: llegar antes implica esperar, no rompe

/** Timestamp RFC3339 en hora de Argentina. "24:00" (cierre a medianoche) → 23:59:59. */
function isoFecha(fecha: string, hhmm: string): string {
  const t = hhmm === "24:00" ? "23:59:59" : `${hhmm}:00`;
  return `${fecha}T${t}${TZ}`;
}

export interface OptimizeToursOpts {
  /** "YYYY-MM-DD" de la entrega. */
  fecha?: string;
  /** "HH:MM" a la que sale del depósito. */
  horaInicio?: string;
  /** Ventanas de entrega por pedido (de cliente.horario_entrega). */
  ventanas?: Array<{ pedido_id: string | number; inicio: string; fin: string }>;
}

/**
 * Llama a optimizeTours: 1 shipment por pedido (delivery en la ubicación del
 * cliente, label = pedido_id), 1 vehículo que arranca en el depósito y termina
 * en `destino` (el punto de llegada configurable; por defecto = depósito).
 *
 * Si `opts.fecha` + `opts.horaInicio` están presentes, agrega el ancla temporal
 * (globalStartTime + arranque del vehículo) y, por cada pedido con ventana, una
 * timeWindow BLANDA con penalización alta por llegar tarde: el optimizador
 * adelanta esas paradas por sobre el ahorro de distancia, pero nunca las saltea.
 */
export async function optimizeTours(
  saKeyJson: string,
  deposito: LatLng,
  pedidos: PedidoRuta[],
  destino: LatLng = deposito,
  opts: OptimizeToursOpts = {},
): Promise<RutaUnida> {
  const sa = JSON.parse(saKeyJson) as ServiceAccountKey;
  const token = await getAccessToken(sa);

  const usarTiempos = !!(opts.fecha && opts.horaInicio);
  const ventanasMap = new Map<string, { inicio: string; fin: string }>();
  for (const v of opts.ventanas ?? []) {
    ventanasMap.set(String(v.pedido_id), { inicio: v.inicio, fin: v.fin });
  }

  const model: Record<string, unknown> = {
    shipments: pedidos.map((p) => {
      const delivery: Record<string, unknown> = {
        arrivalLocation: { latitude: p.latitud, longitude: p.longitud },
      };
      if (usarTiempos) {
        delivery.duration = `${SERVICE_SECONDS}s`;
        const win = ventanasMap.get(String(p.pedido_id));
        if (win) {
          delivery.timeWindows = [{
            softStartTime: isoFecha(opts.fecha!, win.inicio),
            softEndTime: isoFecha(opts.fecha!, win.fin),
            costPerHourBeforeSoftStartTime: COST_EARLY_PER_HOUR,
            costPerHourAfterSoftEndTime: COST_LATE_PER_HOUR,
          }];
        }
      }
      return { label: String(p.pedido_id), deliveries: [delivery] };
    }),
    vehicles: [{
      // startLocation plano (NO startWaypoint anidado) y endLocation en el
      // punto de llegada.
      startLocation: { latitude: deposito.latitude, longitude: deposito.longitude },
      endLocation: { latitude: destino.latitude, longitude: destino.longitude },
      ...(usarTiempos
        ? {
          startTimeWindows: [{
            startTime: isoFecha(opts.fecha!, opts.horaInicio!),
            endTime: isoFecha(opts.fecha!, opts.horaInicio!),
          }],
        }
        : {}),
    }],
  };
  if (usarTiempos) {
    model.globalStartTime = isoFecha(opts.fecha!, opts.horaInicio!);
    model.globalEndTime = `${opts.fecha!}T23:59:59${TZ}`;
  }

  const body = {
    model,
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

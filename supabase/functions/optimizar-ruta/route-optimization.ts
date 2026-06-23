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
  vehicleIndex?: number;
  vehicleLabel?: string;
  visits?: OptimizeToursVisit[];
  routePolyline?: { points?: string };
  metrics?: { travelDistanceMeters?: number; totalDuration?: string };
}
interface OptimizeToursSkipped {
  index?: number;
  label?: string;
  reasons?: Array<{ code?: string; exampleVehicleIndex?: number; exampleExceededCapacityType?: string }>;
}
export interface OptimizeToursResponse {
  routes?: OptimizeToursRoute[];
  skippedShipments?: OptimizeToursSkipped[];
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

// ============================================================================
// Multi-vehículo: dividir la ruta entre N repartidores en una sola llamada.
// ============================================================================

/** Penalización (costo) por asignar un pedido a un chofer que NO prefiere su
 *  zona. Soft: sesga la asignación sin volver el modelo infeasible (a diferencia
 *  de allowedVehicleIndices, que es hard). */
const COST_ZONA_NO_PREFERIDA = 1000;
/** Costo alto por dejar un pedido sin asignar: solo se "saltea" si es infeasible
 *  por capacidad (Σ max_paradas < #pedidos), nunca por ahorro de distancia. */
const PENALTY_NO_ASIGNADO = 1_000_000_000;

/** Pedido con su zona (para el sesgo por zona). */
export type PedidoRutaZona = PedidoRuta & { zona_id?: number | null };

/** Un repartidor disponible y sus parámetros para el split. */
export interface RepartidorVehiculo {
  transportista_id: string;
  /** Tope de paradas para este chofer (loadLimit). Sin valor = sin tope. */
  max_paradas?: number | null;
  /** Zonas que prefiere (soft). Pedidos de esas zonas se sesgan hacia él. */
  zonas_preferidas?: number[] | null;
}

/** Ruta optimizada de un repartidor. */
export interface RutaPorVehiculo extends RutaUnida {
  transportista_id: string;
}

export interface RutaMultiResultado {
  recorridos: RutaPorVehiculo[];
  /** pedido_id de los pedidos que el optimizador no pudo asignar (capacidad). */
  skipped: string[];
}

/** Construye el ordenOptimizado + métricas de una sola ruta (vehículo). */
function parseRutaVehiculo(route: OptimizeToursRoute, byLabel: Map<string, PedidoRuta>): RutaUnida {
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
 * Mapea la respuesta multi-vehículo a una ruta por repartidor. Cada `route`
 * trae su vehicleLabel (= transportista_id) o vehicleIndex; los `visits` son las
 * paradas de ese chofer. Devuelve también los pedidos no asignados. Pura/testeable.
 */
export function parseOptimizeToursMulti(
  data: OptimizeToursResponse,
  pedidos: PedidoRuta[],
  vehicleLabels: string[],
): RutaMultiResultado {
  const byLabel = new Map(pedidos.map((p) => [String(p.pedido_id), p]));
  const recorridos: RutaPorVehiculo[] = [];

  for (const route of data.routes ?? []) {
    const label = route.vehicleLabel
      ?? (route.vehicleIndex != null ? vehicleLabels[route.vehicleIndex] : undefined);
    if (!label) continue;
    const ruta = parseRutaVehiculo(route, byLabel);
    // Saltear vehículos sin paradas (chofer disponible al que no le tocó nada).
    if (ruta.ordenOptimizado.length === 0) continue;
    recorridos.push({ transportista_id: label, ...ruta });
  }

  const skipped = (data.skippedShipments ?? [])
    .map((s) => s.label != null ? String(s.label) : (s.index != null ? String(pedidos[s.index]?.pedido_id ?? "") : ""))
    .filter((x) => x !== "");

  return { recorridos, skipped };
}

/**
 * Optimización multi-vehículo: 1 shipment por pedido, N vehículos (uno por
 * repartidor, label = transportista_id). Parámetros:
 *  - max_paradas por chofer → loadLimits/loadDemands (capacidad "paradas").
 *  - zonas_preferidas → costsPerVehicle SOFT: penaliza asignar el pedido a un
 *    chofer que no prefiere su zona (sin volverlo infeasible).
 * Las ventanas horarias se aplican igual que en el modo 1 vehículo.
 */
export async function optimizeToursMulti(
  saKeyJson: string,
  deposito: LatLng,
  pedidos: PedidoRutaZona[],
  destino: LatLng = deposito,
  opts: OptimizeToursOpts = {},
  repartidores: RepartidorVehiculo[] = [],
): Promise<RutaMultiResultado> {
  if (repartidores.length === 0) throw new Error("No hay repartidores para el split");

  const sa = JSON.parse(saKeyJson) as ServiceAccountKey;
  const token = await getAccessToken(sa);

  const usarTiempos = !!(opts.fecha && opts.horaInicio);
  const ventanasMap = new Map<string, { inicio: string; fin: string }>();
  for (const v of opts.ventanas ?? []) {
    ventanasMap.set(String(v.pedido_id), { inicio: v.inicio, fin: v.fin });
  }

  // Costos por zona: para un pedido cuya zona prefiere AL MENOS un chofer, se
  // penaliza a los choferes que NO la prefieren. Si nadie la prefiere (o el
  // pedido no tiene zona), no se sesga.
  const costosZona = (zonaId: number | null | undefined): { idx: number[]; cost: number[] } | null => {
    if (zonaId == null) return null;
    const prefiere = repartidores.map((r) => Array.isArray(r.zonas_preferidas) && r.zonas_preferidas.includes(zonaId));
    if (!prefiere.some(Boolean)) return null;
    const idx: number[] = [];
    const cost: number[] = [];
    prefiere.forEach((pref, i) => { if (!pref) { idx.push(i); cost.push(COST_ZONA_NO_PREFERIDA); } });
    return idx.length > 0 ? { idx, cost } : null;
  };

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
      const shipment: Record<string, unknown> = {
        label: String(p.pedido_id),
        deliveries: [delivery],
        // 1 unidad de carga "paradas" por pedido (para los loadLimits por chofer).
        loadDemands: { paradas: { amount: "1" } },
        // Permite saltear (no asignar) si es infeasible por capacidad, con costo
        // altísimo para que solo ocurra cuando no hay alternativa.
        penaltyCost: PENALTY_NO_ASIGNADO,
      };
      const cz = costosZona(p.zona_id);
      if (cz) {
        shipment.costsPerVehicleIndices = cz.idx;
        shipment.costsPerVehicle = cz.cost;
      }
      return shipment;
    }),
    vehicles: repartidores.map((r) => {
      const vehicle: Record<string, unknown> = {
        label: r.transportista_id,
        startLocation: { latitude: deposito.latitude, longitude: deposito.longitude },
        endLocation: { latitude: destino.latitude, longitude: destino.longitude },
      };
      if (r.max_paradas != null && r.max_paradas > 0) {
        vehicle.loadLimits = { paradas: { maxLoad: String(Math.floor(r.max_paradas)) } };
      }
      if (usarTiempos) {
        vehicle.startTimeWindows = [{
          startTime: isoFecha(opts.fecha!, opts.horaInicio!),
          endTime: isoFecha(opts.fecha!, opts.horaInicio!),
        }];
      }
      return vehicle;
    }),
  };
  if (usarTiempos) {
    model.globalStartTime = isoFecha(opts.fecha!, opts.horaInicio!);
    model.globalEndTime = `${opts.fecha!}T23:59:59${TZ}`;
  }

  const body = { model, populatePolylines: true };

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
  return parseOptimizeToursMulti(data, pedidos, repartidores.map((r) => r.transportista_id));
}

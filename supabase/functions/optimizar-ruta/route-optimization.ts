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
  /** RFC3339. Cuándo el vehículo termina su recorrido: ancla temporal de la barrida siguiente. */
  vehicleEndTime?: string;
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
 * Extrae "HH:MM" de un RFC3339 en hora de Argentina.
 * Se lee del string en vez de construir un Date para no depender de la zona
 * horaria del runtime de la edge function (que es UTC).
 */
export function hhmmDesdeIso(iso: string | undefined): string | null {
  if (!iso) return null;
  const m = /T(\d{2}):(\d{2})/.exec(iso);
  return m ? `${m[1]}:${m[2]}` : null;
}

/** Ruta de una barrida: además del recorrido, dónde y cuándo terminó. */
export interface RutaTramo extends RutaUnida {
  /** Ubicación de la última parada: origen de la barrida siguiente. */
  ultimaParada: LatLng | null;
  /** "HH:MM" de fin: hora de arranque de la barrida siguiente. */
  horaFin: string | null;
}

/**
 * Mapea la respuesta de optimizeTours a RutaUnida. El orden óptimo son los
 * `visits` (cada uno con `shipmentLabel` = pedido_id); la geometría es la
 * `routePolyline` única del vehículo. Pura/testeable.
 */
export function parseOptimizeTours(data: OptimizeToursResponse, pedidos: PedidoRuta[]): RutaTramo {
  const route = data.routes?.[0];
  if (!route) throw new Error("Route Optimization no devolvió ninguna ruta");

  const byLabel = new Map(pedidos.map((p) => [String(p.pedido_id), p]));
  const ordenOptimizado: OrdenOptimizadoItem[] = [];
  let ultimaParada: LatLng | null = null;

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
    ultimaParada = { latitude: p.latitud, longitude: p.longitud };
  }

  const distanciaTotalMetros = route.metrics?.travelDistanceMeters ?? 0;
  const duracionTotalSegundos = parseDuracion(route.metrics?.totalDuration);
  const polylines = route.routePolyline?.points ? [route.routePolyline.points] : [];

  return {
    ordenOptimizado,
    distanciaTotalMetros,
    duracionTotalSegundos,
    polylines,
    ultimaParada,
    horaFin: hhmmDesdeIso(route.vehicleEndTime),
  };
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
  /** "HH:MM" a la que arranca el vehículo (del depósito, o de la barrida anterior). */
  horaInicio?: string;
  /**
   * Ventanas de entrega por pedido, derivadas del horario del cliente.
   * Cada pedido puede tener MÁS DE UNA franja (horario cortado): Google acepta
   * varias timeWindows por shipment y elige la que menos cuesta. Antes se
   * mandaba solo la primera, así que un local de 08-14 y 17-23 perdía la tarde.
   */
  ventanas?: Array<{
    pedido_id: string | number;
    franjas: Array<{ inicio: string; fin: string }>;
  }>;
}

/** Convierte las franjas de un pedido a timeWindows blandas de la API. */
function timeWindowsDe(
  franjas: Array<{ inicio: string; fin: string }>,
  fecha: string,
): Array<Record<string, unknown>> {
  return franjas.map((f) => ({
    softStartTime: isoFecha(fecha, f.inicio),
    softEndTime: isoFecha(fecha, f.fin),
    costPerHourBeforeSoftStartTime: COST_EARLY_PER_HOUR,
    costPerHourAfterSoftEndTime: COST_LATE_PER_HOUR,
  }));
}

/**
 * Arma el `model` del request de optimizeTours para un vehículo.
 *
 * Está extraída como función PURA a propósito: antes vivía dentro de la async
 * que hace el fetch, y por eso los tests solo podían cubrir los `parse*`. Toda
 * la lógica de ventanas, ancla temporal y ruta abierta se testea acá.
 *
 * @param destino `null` deja el vehículo SIN `endLocation` (ruta abierta): así
 *   termina en su última parada en vez de volver al depósito, que es lo que
 *   permite encadenar una barrida con la siguiente sin kilómetros de más.
 */
export function construirModeloSingle(
  deposito: LatLng,
  pedidos: PedidoRuta[],
  destino: LatLng | null,
  opts: OptimizeToursOpts = {},
): Record<string, unknown> {
  const usarTiempos = !!(opts.fecha && opts.horaInicio);
  const ventanasMap = new Map<string, Array<{ inicio: string; fin: string }>>();
  for (const v of opts.ventanas ?? []) {
    if (v.franjas?.length) ventanasMap.set(String(v.pedido_id), v.franjas);
  }

  const vehicle: Record<string, unknown> = {
    startLocation: { latitude: deposito.latitude, longitude: deposito.longitude },
  };
  if (destino) {
    vehicle.endLocation = { latitude: destino.latitude, longitude: destino.longitude };
  }
  if (usarTiempos) {
    vehicle.startTimeWindows = [{
      startTime: isoFecha(opts.fecha!, opts.horaInicio!),
      endTime: isoFecha(opts.fecha!, opts.horaInicio!),
    }];
  }

  const model: Record<string, unknown> = {
    shipments: pedidos.map((p) => {
      const delivery: Record<string, unknown> = {
        arrivalLocation: { latitude: p.latitud, longitude: p.longitud },
      };
      if (usarTiempos) {
        delivery.duration = `${SERVICE_SECONDS}s`;
        const franjas = ventanasMap.get(String(p.pedido_id));
        if (franjas) delivery.timeWindows = timeWindowsDe(franjas, opts.fecha!);
      }
      return { label: String(p.pedido_id), deliveries: [delivery] };
    }),
    vehicles: [vehicle],
  };

  if (usarTiempos) {
    model.globalStartTime = isoFecha(opts.fecha!, opts.horaInicio!);
    model.globalEndTime = `${opts.fecha!}T23:59:59${TZ}`;
  }

  return model;
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
  destino: LatLng | null = deposito,
  opts: OptimizeToursOpts = {},
): Promise<RutaTramo> {
  const sa = JSON.parse(saKeyJson) as ServiceAccountKey;
  const token = await getAccessToken(sa);

  const body = {
    model: construirModeloSingle(deposito, pedidos, destino, opts),
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
// Barridas: el orden ENTRE bloques es duro.
// ============================================================================

export type Barrida = 1 | 2 | 3;

/** Pedido con la barrida que le asignó el cliente (ver src/utils/barridas.ts). */
export type PedidoRutaBarrida = PedidoRuta & { barrida?: Barrida };

export type OrdenOptimizadoItemBarrida = OrdenOptimizadoItem & { barrida: Barrida };

export interface RutaBarridas extends RutaUnida {
  ordenOptimizado: OrdenOptimizadoItemBarrida[];
  /** Cuántas paradas quedaron en cada barrida (para mostrar en el armado). */
  composicion: Record<Barrida, number>;
}

export const ORDEN_BARRIDAS: Barrida[] = [1, 2, 3];

/**
 * Optimiza en 3 barridas consecutivas, encadenadas.
 *
 * Por qué encadenar 3 llamadas en vez de una sola con ventanas sintéticas:
 * es la única variante que GARANTIZA el orden entre bloques. Con ventanas duras
 * escalonadas el modelo se vuelve infeasible en cuanto hay muchas paradas
 * (8 min de servicio × 30 paradas no entran en un bloque de la mañana), y
 * post-ordenar el resultado de una optimización global produce zigzag, porque
 * el orden interno se calculó para otra secuencia.
 *
 * Cada barrida arranca donde y cuando terminó la anterior: las intermedias van
 * SIN `endLocation` (ruta abierta), así no vuelven al depósito al pedo. Los
 * tiempos acumulados quedan reales, y las ventanas horarias del cliente siguen
 * funcionando dentro de cada bloque.
 *
 * Son 3 requests chicos en lugar de 1 grande: se corre una vez por día, y el
 * costo por shipment es el mismo.
 */
export async function optimizeToursPorBarridas(
  saKeyJson: string,
  deposito: LatLng,
  pedidos: PedidoRutaBarrida[],
  destino: LatLng | null = deposito,
  opts: OptimizeToursOpts = {},
): Promise<RutaBarridas> {
  const grupos: Record<Barrida, PedidoRutaBarrida[]> = { 1: [], 2: [], 3: [] };
  for (const p of pedidos) {
    // Sin clasificación explícita se asume "sin horario" (barrida 2).
    grupos[p.barrida ?? 2].push(p);
  }

  const conPedidos = ORDEN_BARRIDAS.filter((b) => grupos[b].length > 0);
  const composicion: Record<Barrida, number> = {
    1: grupos[1].length,
    2: grupos[2].length,
    3: grupos[3].length,
  };

  const ordenOptimizado: OrdenOptimizadoItemBarrida[] = [];
  const polylines: string[] = [];
  let distanciaTotalMetros = 0;
  let duracionTotalSegundos = 0;

  let origen = deposito;
  let horaInicio = opts.horaInicio;

  for (let i = 0; i < conPedidos.length; i++) {
    const barrida = conPedidos[i];
    const esUltima = i === conPedidos.length - 1;

    const tramo = await optimizeTours(
      saKeyJson,
      origen,
      grupos[barrida],
      // Solo la última barrida termina en el punto de llegada configurado.
      esUltima ? destino : null,
      { ...opts, horaInicio },
    );

    for (const item of tramo.ordenOptimizado) {
      // El orden es global y continuo (1..N), no se reinicia por barrida.
      ordenOptimizado.push({ ...item, orden: ordenOptimizado.length + 1, barrida });
    }
    polylines.push(...tramo.polylines);
    distanciaTotalMetros += tramo.distanciaTotalMetros;
    duracionTotalSegundos += tramo.duracionTotalSegundos;

    // Encadenado. Si la API no devolvió el fin (p.ej. sin ancla temporal), se
    // mantiene el origen/hora previos: peor ruta, nunca un resultado inválido.
    if (tramo.ultimaParada) origen = tramo.ultimaParada;
    if (tramo.horaFin) horaInicio = tramo.horaFin;
  }

  return {
    ordenOptimizado,
    distanciaTotalMetros,
    duracionTotalSegundos,
    polylines,
    composicion,
  };
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
  /**
   * Dónde arranca este chofer. Solo se usa al encadenar barridas: en la 2ª y 3ª
   * cada uno sale de donde terminó la anterior, no del depósito.
   */
  origen?: LatLng | null;
  /** "HH:MM" de arranque propio de este chofer (fin de su barrida anterior). */
  horaInicio?: string | null;
}

/** Ruta optimizada de un repartidor. */
export interface RutaPorVehiculo extends RutaTramo {
  transportista_id: string;
}

export interface RutaMultiResultado {
  recorridos: RutaPorVehiculo[];
  /** pedido_id de los pedidos que el optimizador no pudo asignar (capacidad). */
  skipped: string[];
}

/** Construye el ordenOptimizado + métricas de una sola ruta (vehículo). */
function parseRutaVehiculo(route: OptimizeToursRoute, byLabel: Map<string, PedidoRuta>): RutaTramo {
  const ordenOptimizado: OrdenOptimizadoItem[] = [];
  let ultimaParada: LatLng | null = null;
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
    ultimaParada = { latitude: p.latitud, longitude: p.longitud };
  }
  const distanciaTotalMetros = route.metrics?.travelDistanceMeters ?? 0;
  const duracionTotalSegundos = parseDuracion(route.metrics?.totalDuration);
  const polylines = route.routePolyline?.points ? [route.routePolyline.points] : [];
  return {
    ordenOptimizado,
    distanciaTotalMetros,
    duracionTotalSegundos,
    polylines,
    ultimaParada,
    horaFin: hhmmDesdeIso(route.vehicleEndTime),
  };
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
  destino: LatLng | null = deposito,
  opts: OptimizeToursOpts = {},
  repartidores: RepartidorVehiculo[] = [],
): Promise<RutaMultiResultado> {
  if (repartidores.length === 0) throw new Error("No hay repartidores para el split");

  const sa = JSON.parse(saKeyJson) as ServiceAccountKey;
  const token = await getAccessToken(sa);

  const usarTiempos = !!(opts.fecha && opts.horaInicio);
  const ventanasMap = new Map<string, Array<{ inicio: string; fin: string }>>();
  for (const v of opts.ventanas ?? []) {
    if (v.franjas?.length) ventanasMap.set(String(v.pedido_id), v.franjas);
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
        const franjas = ventanasMap.get(String(p.pedido_id));
        if (franjas) delivery.timeWindows = timeWindowsDe(franjas, opts.fecha!);
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
      // Al encadenar barridas, cada chofer arranca donde terminó la anterior.
      const origen = r.origen ?? deposito;
      const vehicle: Record<string, unknown> = {
        label: r.transportista_id,
        startLocation: { latitude: origen.latitude, longitude: origen.longitude },
      };
      // destino null = ruta abierta (barrida intermedia): termina en la última parada.
      if (destino) {
        vehicle.endLocation = { latitude: destino.latitude, longitude: destino.longitude };
      }
      if (r.max_paradas != null && r.max_paradas > 0) {
        vehicle.loadLimits = { paradas: { maxLoad: String(Math.floor(r.max_paradas)) } };
      }
      if (usarTiempos) {
        const arranque = r.horaInicio ?? opts.horaInicio!;
        vehicle.startTimeWindows = [{
          startTime: isoFecha(opts.fecha!, arranque),
          endTime: isoFecha(opts.fecha!, arranque),
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

/**
 * Split multi-repartidor CON barridas: el orden entre bloques es duro también
 * cuando la ruta se divide entre varios choferes.
 *
 * Se resuelve una barrida por vez con `optimizeToursMulti`, y entre barridas
 * cada vehículo se re-ancla:
 *  - arranca en su última parada de la barrida anterior (o el depósito si no le
 *    tocó nada);
 *  - arranca a la hora en que terminó;
 *  - se le DESCUENTA el cupo ya usado de `max_paradas`. Sin esto el tope se
 *    aplicaría entero en cada barrida y un chofer con tope 20 podía terminar
 *    con 60 paradas.
 */
export async function optimizeToursMultiPorBarridas(
  saKeyJson: string,
  deposito: LatLng,
  pedidos: Array<PedidoRutaZona & { barrida?: Barrida }>,
  destino: LatLng | null = deposito,
  opts: OptimizeToursOpts = {},
  repartidores: RepartidorVehiculo[] = [],
): Promise<RutaMultiResultado & { composicion: Record<Barrida, number> }> {
  if (repartidores.length === 0) throw new Error("No hay repartidores para el split");

  const grupos: Record<Barrida, Array<PedidoRutaZona & { barrida?: Barrida }>> = { 1: [], 2: [], 3: [] };
  for (const p of pedidos) grupos[p.barrida ?? 2].push(p);

  const conPedidos = ORDEN_BARRIDAS.filter((b) => grupos[b].length > 0);
  const composicion: Record<Barrida, number> = {
    1: grupos[1].length,
    2: grupos[2].length,
    3: grupos[3].length,
  };

  // Estado de cada chofer entre barridas.
  const estado = new Map<string, { origen: LatLng; horaInicio: string | null; usadas: number }>();
  for (const r of repartidores) {
    estado.set(r.transportista_id, { origen: deposito, horaInicio: opts.horaInicio ?? null, usadas: 0 });
  }

  const acumulado = new Map<string, RutaPorVehiculo>();
  const skipped: string[] = [];

  for (let i = 0; i < conPedidos.length; i++) {
    const barrida = conPedidos[i];
    const esUltima = i === conPedidos.length - 1;

    // Vehículos con su arranque y cupo restante para ESTA barrida.
    const vehiculos: RepartidorVehiculo[] = [];
    for (const r of repartidores) {
      const st = estado.get(r.transportista_id)!;
      const restante = r.max_paradas != null && r.max_paradas > 0
        ? r.max_paradas - st.usadas
        : null;
      // Un chofer que ya agotó su cupo no participa de las barridas siguientes.
      if (restante != null && restante <= 0) continue;
      vehiculos.push({
        ...r,
        max_paradas: restante,
        origen: st.origen,
        horaInicio: st.horaInicio,
      });
    }
    if (vehiculos.length === 0) {
      // Sin capacidad: los pedidos de esta barrida quedan sin asignar.
      skipped.push(...grupos[barrida].map((p) => String(p.pedido_id)));
      continue;
    }

    const res = await optimizeToursMulti(
      saKeyJson,
      deposito,
      grupos[barrida],
      esUltima ? destino : null,
      opts,
      vehiculos,
    );
    skipped.push(...res.skipped);

    for (const r of res.recorridos) {
      const prev = acumulado.get(r.transportista_id);
      if (!prev) {
        acumulado.set(r.transportista_id, {
          ...r,
          ordenOptimizado: r.ordenOptimizado.map((it, idx) => ({ ...it, orden: idx + 1, barrida })),
        });
      } else {
        for (const it of r.ordenOptimizado) {
          prev.ordenOptimizado.push({ ...it, orden: prev.ordenOptimizado.length + 1, barrida });
        }
        prev.polylines.push(...r.polylines);
        prev.distanciaTotalMetros += r.distanciaTotalMetros;
        prev.duracionTotalSegundos += r.duracionTotalSegundos;
        prev.ultimaParada = r.ultimaParada ?? prev.ultimaParada;
        prev.horaFin = r.horaFin ?? prev.horaFin;
      }

      const st = estado.get(r.transportista_id);
      if (st) {
        st.usadas += r.ordenOptimizado.length;
        if (r.ultimaParada) st.origen = r.ultimaParada;
        if (r.horaFin) st.horaInicio = r.horaFin;
      }
    }
  }

  return { recorridos: [...acumulado.values()], skipped, composicion };
}

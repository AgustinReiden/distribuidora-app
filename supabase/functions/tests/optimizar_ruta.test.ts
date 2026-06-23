// Tests de la lógica pura de tramos de optimizar-ruta (sin red).
// Import vía el alias std/ del deno.json (NO usar la URL literal de
// deno.land: nixpacks la detecta y clasifica el repo entero como Deno,
// rompiendo el build de Coolify).
import { assertEquals } from "std/assert/mod.ts";
import {
  type GoogleRoute,
  MAX_INTERMEDIOS,
  partirEnTramos,
  type PedidoRuta,
  unirTramos,
} from "../optimizar-ruta/tramos.ts";
import { parseOptimizeTours, parseOptimizeToursMulti } from "../optimizar-ruta/route-optimization.ts";

const DEPOSITO = { latitude: -26.8241, longitude: -65.2226 };

function pedido(id: number, lat: number, lng: number): PedidoRuta {
  return { pedido_id: String(id), cliente_nombre: `Cliente ${id}`, latitud: lat, longitud: lng };
}

/** Genera n pedidos repartidos en círculo alrededor del depósito. */
function pedidosEnCirculo(n: number): PedidoRuta[] {
  return Array.from({ length: n }, (_, i) => {
    const ang = (2 * Math.PI * i) / n;
    return pedido(i + 1, DEPOSITO.latitude + 0.05 * Math.sin(ang), DEPOSITO.longitude + 0.05 * Math.cos(ang));
  });
}

Deno.test("con pocos pedidos genera un único tramo depósito → depósito", () => {
  const tramos = partirEnTramos(DEPOSITO, pedidosEnCirculo(10));
  assertEquals(tramos.length, 1);
  assertEquals(tramos[0].origen, DEPOSITO);
  assertEquals(tramos[0].destino, DEPOSITO);
  assertEquals(tramos[0].puente, null);
  assertEquals(tramos[0].intermedios.length, 10);
});

Deno.test("con 50 pedidos parte en tramos de <= MAX_INTERMEDIOS y los encadena", () => {
  const tramos = partirEnTramos(DEPOSITO, pedidosEnCirculo(50));
  assertEquals(tramos.length, 3);

  // Ningún tramo supera el límite de intermedios de Google
  for (const t of tramos) {
    assertEquals(t.intermedios.length <= MAX_INTERMEDIOS, true);
  }

  // Encadenado: el origen de cada tramo es el puente del anterior, y el
  // último vuelve al depósito sin puente.
  assertEquals(tramos[0].origen, DEPOSITO);
  for (let i = 1; i < tramos.length; i++) {
    const puenteAnterior = tramos[i - 1].puente!;
    assertEquals(tramos[i].origen, {
      latitude: puenteAnterior.latitud,
      longitude: puenteAnterior.longitud,
    });
  }
  assertEquals(tramos[tramos.length - 1].puente, null);
  assertEquals(tramos[tramos.length - 1].destino, DEPOSITO);

  // Todos los pedidos quedan cubiertos exactamente una vez (intermedios + puentes)
  const ids = tramos.flatMap((t) => [
    ...t.intermedios.map((p) => p.pedido_id),
    ...(t.puente ? [t.puente.pedido_id] : []),
  ]);
  assertEquals(new Set(ids).size, 50);
  assertEquals(ids.length, 50);
});

Deno.test("partirEnTramos con punto de llegada: el último tramo termina en el destino", () => {
  const destino = { latitude: -26.90, longitude: -65.30 };

  // Un solo tramo: origen = depósito, destino = punto de llegada.
  const uno = partirEnTramos(DEPOSITO, pedidosEnCirculo(10), destino);
  assertEquals(uno.length, 1);
  assertEquals(uno[0].origen, DEPOSITO);
  assertEquals(uno[0].destino, destino);

  // Tres tramos: SOLO el último termina en el destino; los previos en su puente.
  const tres = partirEnTramos(DEPOSITO, pedidosEnCirculo(50), destino);
  assertEquals(tres.length, 3);
  assertEquals(tres[0].origen, DEPOSITO);
  assertEquals(tres[tres.length - 1].destino, destino);
  assertEquals(tres[0].destino, {
    latitude: tres[0].puente!.latitud,
    longitude: tres[0].puente!.longitud,
  });
});

Deno.test("partirEnTramos sin punto de llegada: termina en el depósito (compat)", () => {
  const tramos = partirEnTramos(DEPOSITO, pedidosEnCirculo(10));
  assertEquals(tramos[0].destino, DEPOSITO);
});

Deno.test("unirTramos respeta el orden optimizado de Google y suma totales", () => {
  const pedidos = [pedido(1, -26.80, -65.20), pedido(2, -26.81, -65.21), pedido(3, -26.82, -65.22)];
  const tramos = partirEnTramos(DEPOSITO, pedidos);
  assertEquals(tramos.length, 1);

  // Google reordena los 3 intermedios: visita el 2º, luego el 0º, luego el 1º
  // (índices sobre tramos[0].intermedios). 4 legs: 3 llegadas + vuelta al depósito.
  const ruta: GoogleRoute = {
    optimizedIntermediateWaypointIndex: [2, 0, 1],
    polyline: { encodedPolyline: "_p~iF~ps|U" },
    legs: [
      { distanceMeters: 1000, duration: "60s" },
      { distanceMeters: 2000, duration: "120s" },
      { distanceMeters: 3000, duration: "180s" },
      { distanceMeters: 4000, duration: "240s" },
    ],
  };

  const unida = unirTramos(tramos, [ruta]);
  assertEquals(unida.ordenOptimizado.length, 3);
  // La polyline del tramo se recolecta en orden
  assertEquals(unida.polylines, ["_p~iF~ps|U"]);
  assertEquals(unida.ordenOptimizado.map((o) => o.orden), [1, 2, 3]);
  assertEquals(
    unida.ordenOptimizado.map((o) => o.pedido_id),
    [tramos[0].intermedios[2], tramos[0].intermedios[0], tramos[0].intermedios[1]].map((p) =>
      p.pedido_id
    ),
  );
  // Totales incluyen la vuelta al depósito (leg 4)
  assertEquals(unida.distanciaTotalMetros, 10000);
  assertEquals(unida.duracionTotalSegundos, 600);
});

Deno.test("unirTramos con dos tramos: el puente se visita al final de su tramo y el orden es global", () => {
  // Forzar 2 tramos con 30 pedidos
  const tramos = partirEnTramos(DEPOSITO, pedidosEnCirculo(30));
  assertEquals(tramos.length, 2);
  const [t1, t2] = tramos;

  const legsDe = (n: number) =>
    Array.from({ length: n }, () => ({ distanceMeters: 100, duration: "10s" }));

  const rutas: GoogleRoute[] = [
    // Tramo 1: sin reordenar; legs = intermedios + llegada al puente
    { legs: legsDe(t1.intermedios.length + 1) },
    // Tramo 2 (último): legs = intermedios + vuelta al depósito
    { legs: legsDe(t2.intermedios.length + 1) },
  ];

  const unida = unirTramos(tramos, rutas);
  assertEquals(unida.ordenOptimizado.length, 30);
  // El puente del tramo 1 ocupa la última posición de su tramo
  assertEquals(unida.ordenOptimizado[t1.intermedios.length].pedido_id, t1.puente!.pedido_id);
  // Orden global incremental 1..30
  assertEquals(unida.ordenOptimizado.map((o) => o.orden), Array.from({ length: 30 }, (_, i) => i + 1));
  // Totales: todos los legs (30 llegadas + 1 puente... 31 legs de 100m? No:
  // t1 tiene |int|+1 legs y t2 |int|+1 legs = 30 llegadas + vuelta = 31 legs)
  assertEquals(unida.distanciaTotalMetros, 3100);
});

// --- Route Optimization API (optimizeTours) ---

Deno.test("parseOptimizeTours mapea visits al orden por shipmentLabel y la polyline única", () => {
  const pedidos: PedidoRuta[] = [
    { pedido_id: "10", cliente_nombre: "A", latitud: -26.80, longitud: -65.20 },
    { pedido_id: "20", cliente_nombre: "B", latitud: -26.81, longitud: -65.21 },
    { pedido_id: "30", cliente_nombre: "C", latitud: -26.82, longitud: -65.22 },
  ];
  // Google devuelve el orden óptimo: 30, 10, 20
  const data = {
    routes: [{
      visits: [
        { shipmentLabel: "30" },
        { shipmentLabel: "10" },
        { shipmentLabel: "20" },
      ],
      routePolyline: { points: "_p~iF~ps|U" },
      metrics: { travelDistanceMeters: 12345, totalDuration: "1800s" },
    }],
  };

  const ruta = parseOptimizeTours(data, pedidos);
  assertEquals(ruta.ordenOptimizado.map((o) => o.pedido_id), ["30", "10", "20"]);
  assertEquals(ruta.ordenOptimizado.map((o) => o.orden), [1, 2, 3]);
  assertEquals(ruta.ordenOptimizado[0].cliente, "C");
  assertEquals(ruta.distanciaTotalMetros, 12345);
  assertEquals(ruta.duracionTotalSegundos, 1800);
  assertEquals(ruta.polylines, ["_p~iF~ps|U"]);
});

Deno.test("parseOptimizeTours ignora visits sin label y rutas sin polyline", () => {
  const pedidos: PedidoRuta[] = [
    { pedido_id: "1", latitud: -26.8, longitud: -65.2 },
  ];
  const data = {
    routes: [{
      visits: [{ shipmentIndex: 0 }, { shipmentLabel: "1" }],
      metrics: { travelDistanceMeters: 500 },
    }],
  };
  const ruta = parseOptimizeTours(data, pedidos);
  assertEquals(ruta.ordenOptimizado.length, 1);
  assertEquals(ruta.ordenOptimizado[0].pedido_id, "1");
  assertEquals(ruta.polylines, []);
  assertEquals(ruta.duracionTotalSegundos, 0);
});

// --- Split multi-vehículo (parseOptimizeToursMulti) ---

Deno.test("parseOptimizeToursMulti reparte las visitas por vehicleLabel (transportista)", () => {
  const pedidos: PedidoRuta[] = [
    { pedido_id: "1", cliente_nombre: "A", latitud: -26.80, longitud: -65.20 },
    { pedido_id: "2", cliente_nombre: "B", latitud: -26.81, longitud: -65.21 },
    { pedido_id: "3", cliente_nombre: "C", latitud: -26.82, longitud: -65.22 },
  ];
  const data = {
    routes: [
      {
        vehicleLabel: "chofer-A",
        visits: [{ shipmentLabel: "1" }, { shipmentLabel: "3" }],
        routePolyline: { points: "abc" },
        metrics: { travelDistanceMeters: 1200, totalDuration: "600s" },
      },
      {
        vehicleLabel: "chofer-B",
        visits: [{ shipmentLabel: "2" }],
        routePolyline: { points: "def" },
        metrics: { travelDistanceMeters: 800, totalDuration: "300s" },
      },
    ],
  };

  const { recorridos, skipped } = parseOptimizeToursMulti(data, pedidos, ["chofer-A", "chofer-B"]);
  assertEquals(recorridos.length, 2);
  assertEquals(recorridos[0].transportista_id, "chofer-A");
  assertEquals(recorridos[0].ordenOptimizado.map((o) => o.pedido_id), ["1", "3"]);
  assertEquals(recorridos[0].ordenOptimizado.map((o) => o.orden), [1, 2]);
  assertEquals(recorridos[0].polylines, ["abc"]);
  assertEquals(recorridos[0].distanciaTotalMetros, 1200);
  assertEquals(recorridos[0].duracionTotalSegundos, 600);
  assertEquals(recorridos[1].transportista_id, "chofer-B");
  assertEquals(recorridos[1].ordenOptimizado.map((o) => o.pedido_id), ["2"]);
  assertEquals(skipped, []);
});

Deno.test("parseOptimizeToursMulti usa vehicleIndex cuando falta el label y saltea rutas vacías", () => {
  const pedidos: PedidoRuta[] = [
    { pedido_id: "1", latitud: -26.80, longitud: -65.20 },
    { pedido_id: "2", latitud: -26.81, longitud: -65.21 },
  ];
  const data = {
    routes: [
      { vehicleIndex: 0, visits: [{ shipmentLabel: "1" }, { shipmentLabel: "2" }] },
      { vehicleIndex: 1, visits: [] }, // chofer sin paradas → se saltea
    ],
  };
  const { recorridos } = parseOptimizeToursMulti(data, pedidos, ["uuid-A", "uuid-B"]);
  assertEquals(recorridos.length, 1);
  assertEquals(recorridos[0].transportista_id, "uuid-A");
  assertEquals(recorridos[0].ordenOptimizado.length, 2);
});

Deno.test("parseOptimizeToursMulti devuelve los pedidos no asignados (skippedShipments)", () => {
  const pedidos: PedidoRuta[] = [
    { pedido_id: "1", latitud: -26.80, longitud: -65.20 },
    { pedido_id: "2", latitud: -26.81, longitud: -65.21 },
  ];
  const data = {
    routes: [{ vehicleLabel: "A", visits: [{ shipmentLabel: "1" }] }],
    skippedShipments: [{ index: 1, label: "2", reasons: [{ code: "DEMAND_EXCEEDS_VEHICLE_CAPACITY" }] }],
  };
  const { recorridos, skipped } = parseOptimizeToursMulti(data, pedidos, ["A"]);
  assertEquals(recorridos.length, 1);
  assertEquals(skipped, ["2"]);
});

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

Deno.test("unirTramos respeta el orden optimizado de Google y suma totales", () => {
  const pedidos = [pedido(1, -26.80, -65.20), pedido(2, -26.81, -65.21), pedido(3, -26.82, -65.22)];
  const tramos = partirEnTramos(DEPOSITO, pedidos);
  assertEquals(tramos.length, 1);

  // Google reordena los 3 intermedios: visita el 2º, luego el 0º, luego el 1º
  // (índices sobre tramos[0].intermedios). 4 legs: 3 llegadas + vuelta al depósito.
  const ruta: GoogleRoute = {
    optimizedIntermediateWaypointIndex: [2, 0, 1],
    legs: [
      { distanceMeters: 1000, duration: "60s" },
      { distanceMeters: 2000, duration: "120s" },
      { distanceMeters: 3000, duration: "180s" },
      { distanceMeters: 4000, duration: "240s" },
    ],
  };

  const unida = unirTramos(tramos, [ruta]);
  assertEquals(unida.ordenOptimizado.length, 3);
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

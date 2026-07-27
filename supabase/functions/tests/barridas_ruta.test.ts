// Tests del armado del request de optimizeTours y del encadenado por barridas.
//
// Antes esta lógica vivía dentro de la función async que hace el fetch, así que
// los tests solo podían cubrir los `parse*`. Al extraer `construirModeloSingle`
// como función pura se puede verificar lo que realmente importa: que las
// ventanas horarias lleguen bien armadas y que las barridas intermedias queden
// sin `endLocation` (ruta abierta) para poder encadenarlas.
import { assertEquals, assertExists } from "std/assert/mod.ts";
import {
  construirModeloSingle,
  hhmmDesdeIso,
  parseOptimizeTours,
} from "../optimizar-ruta/route-optimization.ts";
import type { PedidoRuta } from "../optimizar-ruta/tramos.ts";

const DEPOSITO = { latitude: -26.8241, longitude: -65.2226 };
const DESTINO = { latitude: -26.83, longitude: -65.21 };
const FECHA = "2026-07-28";

function pedido(id: number, lat = -26.8, lng = -65.2): PedidoRuta {
  return { pedido_id: String(id), cliente_nombre: `Cliente ${id}`, latitud: lat, longitud: lng };
}

// deno-lint-ignore no-explicit-any
const shipments = (m: Record<string, unknown>) => m.shipments as any[];
// deno-lint-ignore no-explicit-any
const vehiculo = (m: Record<string, unknown>) => (m.vehicles as any[])[0];

Deno.test("sin fecha/hora no se arma ancla temporal ni ventanas", () => {
  const m = construirModeloSingle(DEPOSITO, [pedido(1)], DESTINO, {});
  assertEquals(m.globalStartTime, undefined);
  assertEquals(shipments(m)[0].deliveries[0].timeWindows, undefined);
  assertEquals(vehiculo(m).startTimeWindows, undefined);
});

Deno.test("con fecha y hora se ancla el arranque del vehículo", () => {
  const m = construirModeloSingle(DEPOSITO, [pedido(1)], DESTINO, {
    fecha: FECHA,
    horaInicio: "08:00",
  });
  assertEquals(m.globalStartTime, `${FECHA}T08:00:00-03:00`);
  assertEquals(vehiculo(m).startTimeWindows[0].startTime, `${FECHA}T08:00:00-03:00`);
  assertEquals(shipments(m)[0].deliveries[0].duration, "480s");
});

Deno.test("el horario cortado manda LAS DOS franjas como timeWindows", () => {
  // Regresión: antes se mandaba solo la primera franja, así que un local de
  // 08-14 y 17-23 perdía toda la ventana de la tarde.
  const m = construirModeloSingle(DEPOSITO, [pedido(1)], DESTINO, {
    fecha: FECHA,
    horaInicio: "08:00",
    ventanas: [{
      pedido_id: "1",
      franjas: [{ inicio: "08:00", fin: "14:00" }, { inicio: "17:00", fin: "23:00" }],
    }],
  });
  const tw = shipments(m)[0].deliveries[0].timeWindows;
  assertEquals(tw.length, 2);
  assertEquals(tw[0].softStartTime, `${FECHA}T08:00:00-03:00`);
  assertEquals(tw[0].softEndTime, `${FECHA}T14:00:00-03:00`);
  assertEquals(tw[1].softStartTime, `${FECHA}T17:00:00-03:00`);
  assertEquals(tw[1].softEndTime, `${FECHA}T23:00:00-03:00`);
});

Deno.test("llegar tarde cuesta mucho más que llegar temprano", () => {
  const m = construirModeloSingle(DEPOSITO, [pedido(1)], DESTINO, {
    fecha: FECHA,
    horaInicio: "08:00",
    ventanas: [{ pedido_id: "1", franjas: [{ inicio: "09:00", fin: "14:00" }] }],
  });
  const tw = shipments(m)[0].deliveries[0].timeWindows[0];
  assertEquals(tw.costPerHourAfterSoftEndTime > tw.costPerHourBeforeSoftStartTime, true);
});

Deno.test("el cierre a las 24:00 se traduce a 23:59:59 del mismo día", () => {
  const m = construirModeloSingle(DEPOSITO, [pedido(1)], DESTINO, {
    fecha: FECHA,
    horaInicio: "08:00",
    ventanas: [{ pedido_id: "1", franjas: [{ inicio: "10:00", fin: "24:00" }] }],
  });
  assertEquals(
    shipments(m)[0].deliveries[0].timeWindows[0].softEndTime,
    `${FECHA}T23:59:59-03:00`,
  );
});

Deno.test("un pedido sin ventana queda flexible (sin timeWindows)", () => {
  const m = construirModeloSingle(DEPOSITO, [pedido(1), pedido(2)], DESTINO, {
    fecha: FECHA,
    horaInicio: "08:00",
    ventanas: [{ pedido_id: "1", franjas: [{ inicio: "09:00", fin: "14:00" }] }],
  });
  assertExists(shipments(m)[0].deliveries[0].timeWindows);
  assertEquals(shipments(m)[1].deliveries[0].timeWindows, undefined);
});

Deno.test("ventana con franjas vacías se ignora en vez de romper", () => {
  const m = construirModeloSingle(DEPOSITO, [pedido(1)], DESTINO, {
    fecha: FECHA,
    horaInicio: "08:00",
    ventanas: [{ pedido_id: "1", franjas: [] }],
  });
  assertEquals(shipments(m)[0].deliveries[0].timeWindows, undefined);
});

Deno.test("destino null = ruta abierta: el vehículo NO vuelve al depósito", () => {
  // Es lo que permite encadenar una barrida con la siguiente sin kilómetros
  // de más: la barrida intermedia termina en su última parada.
  const m = construirModeloSingle(DEPOSITO, [pedido(1)], null, {
    fecha: FECHA,
    horaInicio: "08:00",
  });
  assertEquals(vehiculo(m).endLocation, undefined);
  assertEquals(vehiculo(m).startLocation, {
    latitude: DEPOSITO.latitude,
    longitude: DEPOSITO.longitude,
  });
});

Deno.test("con destino se fija el punto de llegada", () => {
  const m = construirModeloSingle(DEPOSITO, [pedido(1)], DESTINO, {});
  assertEquals(vehiculo(m).endLocation, {
    latitude: DESTINO.latitude,
    longitude: DESTINO.longitude,
  });
});

Deno.test("la barrida siguiente puede arrancar donde terminó la anterior", () => {
  const origenTramo2 = { latitude: -26.79, longitude: -65.19 };
  const m = construirModeloSingle(origenTramo2, [pedido(9)], null, {
    fecha: FECHA,
    horaInicio: "12:30",
  });
  assertEquals(vehiculo(m).startLocation, {
    latitude: origenTramo2.latitude,
    longitude: origenTramo2.longitude,
  });
  assertEquals(vehiculo(m).startTimeWindows[0].startTime, `${FECHA}T12:30:00-03:00`);
});

Deno.test("hhmmDesdeIso extrae la hora local sin depender del TZ del runtime", () => {
  assertEquals(hhmmDesdeIso("2026-07-28T12:34:56-03:00"), "12:34");
  assertEquals(hhmmDesdeIso("2026-07-28T08:00:00-03:00"), "08:00");
  assertEquals(hhmmDesdeIso(undefined), null);
  assertEquals(hhmmDesdeIso("no-es-fecha"), null);
});

Deno.test("parseOptimizeTours devuelve la última parada y la hora de fin", () => {
  // Son los dos datos que encadenan una barrida con la siguiente.
  const pedidos = [pedido(1, -26.81, -65.21), pedido(2, -26.82, -65.22)];
  const ruta = parseOptimizeTours({
    routes: [{
      visits: [{ shipmentLabel: "1" }, { shipmentLabel: "2" }],
      metrics: { travelDistanceMeters: 1000, totalDuration: "600s" },
      vehicleEndTime: "2026-07-28T12:45:00-03:00",
    }],
  }, pedidos);

  assertEquals(ruta.ordenOptimizado.length, 2);
  assertEquals(ruta.ultimaParada, { latitude: -26.82, longitude: -65.22 });
  assertEquals(ruta.horaFin, "12:45");
});

Deno.test("sin vehicleEndTime la hora de fin es null (se mantiene la previa)", () => {
  const ruta = parseOptimizeTours({
    routes: [{ visits: [{ shipmentLabel: "1" }], metrics: {} }],
  }, [pedido(1)]);
  assertEquals(ruta.horaFin, null);
  assertExists(ruta.ultimaParada);
});

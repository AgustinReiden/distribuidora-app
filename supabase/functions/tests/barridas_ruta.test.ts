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
  finDeJornada,
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
  assertEquals(tw[0].startTime, `${FECHA}T08:00:00-03:00`);
  assertEquals(tw[1].startTime, `${FECHA}T17:00:00-03:00`);
});

Deno.test("la apertura es DURA: no se puede entregar con el local cerrado", () => {
  // El caso reclamado: la parada 1 abría 07:30 y la 2 a las 08:30. Con la
  // apertura blanda el modelo podía "entregar" a las 07:45 en la que abre 08:30
  // pagando una multa chica, y el chofer quedaba una hora esperando.
  const m = construirModeloSingle(DEPOSITO, [pedido(1)], DESTINO, {
    fecha: FECHA,
    horaInicio: "08:00",
    ventanas: [{ pedido_id: "1", franjas: [{ inicio: "09:00", fin: "14:00" }] }],
  });
  const tw = shipments(m)[0].deliveries[0].timeWindows[0];
  assertEquals(tw.startTime, `${FECHA}T09:00:00-03:00`);
  assertEquals(tw.softStartTime, undefined);
  assertEquals(tw.costPerHourBeforeSoftStartTime, undefined);
});

Deno.test("el cierre es BLANDO: llegar tarde penaliza, no vuelve infactible el modelo", () => {
  // Si el cierre fuera duro y una parada no entrara antes de que cierre, se
  // caería la ruta entera en vez de una sola entrega.
  const m = construirModeloSingle(DEPOSITO, [pedido(1)], DESTINO, {
    fecha: FECHA,
    horaInicio: "08:00",
    ventanas: [{ pedido_id: "1", franjas: [{ inicio: "09:00", fin: "14:00" }] }],
  });
  const tw = shipments(m)[0].deliveries[0].timeWindows[0];
  assertEquals(tw.softEndTime, `${FECHA}T14:00:00-03:00`);
  assertEquals(tw.endTime, undefined);
  assertEquals(tw.costPerHourAfterSoftEndTime > 0, true);
});

Deno.test("con varias franjas solo la última afloja el cierre (deben ser disjuntas)", () => {
  // Una `endTime` sin especificar toma globalEndTime: si todas las franjas
  // quedaran blandas se solaparían todas a las 23:59 y la API las rechaza.
  const m = construirModeloSingle(DEPOSITO, [pedido(1)], DESTINO, {
    fecha: FECHA,
    horaInicio: "08:00",
    ventanas: [{
      pedido_id: "1",
      franjas: [{ inicio: "08:00", fin: "14:00" }, { inicio: "17:00", fin: "23:00" }],
    }],
  });
  const tw = shipments(m)[0].deliveries[0].timeWindows;
  assertEquals(tw[0].endTime, `${FECHA}T14:00:00-03:00`);
  assertEquals(tw[0].softEndTime, undefined);
  assertEquals(tw[1].softEndTime, `${FECHA}T23:00:00-03:00`);
  assertEquals(tw[1].endTime, undefined);
});

Deno.test("la franja que arranca después del reparto no es una entrega posible", () => {
  // 09-13 y 18-22 saliendo 08:00: el reparto termina 18:00, así que la ventana
  // de la noche no puede usarse como salida de emergencia para dar la parada
  // por resuelta — en la calle esa entrega no se hace.
  const m = construirModeloSingle(DEPOSITO, [pedido(1)], DESTINO, {
    fecha: FECHA,
    horaInicio: "08:00",
    ventanas: [{
      pedido_id: "1",
      franjas: [{ inicio: "09:00", fin: "13:00" }, { inicio: "18:00", fin: "22:00" }],
    }],
  });
  const tw = shipments(m)[0].deliveries[0].timeWindows;
  assertEquals(tw.length, 1);
  assertEquals(tw[0].startTime, `${FECHA}T09:00:00-03:00`);
  assertEquals(tw[0].softEndTime, `${FECHA}T13:00:00-03:00`);
});

Deno.test("el cliente que solo atiende de noche conserva su ventana", () => {
  // Sin franjas útiles se deja la primera: una ventana imposible la penaliza y
  // la manda al final, pero una parada SIN ventana caería en cualquier lado.
  const m = construirModeloSingle(DEPOSITO, [pedido(1)], DESTINO, {
    fecha: FECHA,
    horaInicio: "08:00",
    ventanas: [{ pedido_id: "1", franjas: [{ inicio: "20:00", fin: "23:00" }] }],
  });
  const tw = shipments(m)[0].deliveries[0].timeWindows;
  assertEquals(tw.length, 1);
  assertEquals(tw[0].startTime, `${FECHA}T20:00:00-03:00`);
});

Deno.test("finDeJornada: salida + 10 h, con tope a las 23:30", () => {
  assertEquals(finDeJornada("08:00"), "18:00");
  assertEquals(finDeJornada("07:30"), "17:30");
  assertEquals(finDeJornada("15:00"), "23:30");
  assertEquals(finDeJornada(undefined), null);
  assertEquals(finDeJornada("no-es-hora"), null);
});

Deno.test("el vehículo lleva costos: sin ellos el modelo no tiene qué minimizar", () => {
  // Con todos los costos en cero cualquier orden factible le da lo mismo al
  // solver, y las penalizaciones de ventana quedan como único criterio.
  const m = construirModeloSingle(DEPOSITO, [pedido(1)], DESTINO, {
    fecha: FECHA,
    horaInicio: "08:00",
  });
  assertEquals(vehiculo(m).costPerKilometer > 0, true);
  assertEquals(vehiculo(m).costPerHour > 0, true);
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

Deno.test("cada parada devuelve su hora estimada de llegada", () => {
  // Es lo que permite contrastar el plan contra el horario del cliente ANTES de
  // mandar el camión, en vez de enterarse con la puerta cerrada.
  const ruta = parseOptimizeTours({
    routes: [{
      visits: [
        { shipmentLabel: "1", startTime: "2026-07-28T08:12:00-03:00" },
        { shipmentLabel: "2", startTime: "2026-07-28T08:35:00-03:00" },
      ],
      metrics: {},
    }],
  }, [pedido(1), pedido(2)]);

  assertEquals(ruta.ordenOptimizado[0].hora_estimada, "08:12");
  assertEquals(ruta.ordenOptimizado[1].hora_estimada, "08:35");
});

Deno.test("sin startTime la parada no inventa hora estimada", () => {
  const ruta = parseOptimizeTours({
    routes: [{ visits: [{ shipmentLabel: "1" }], metrics: {} }],
  }, [pedido(1)]);
  assertEquals(ruta.ordenOptimizado[0].hora_estimada, undefined);
});

Deno.test("sin vehicleEndTime la hora de fin es null (se mantiene la previa)", () => {
  const ruta = parseOptimizeTours({
    routes: [{ visits: [{ shipmentLabel: "1" }], metrics: {} }],
  }, [pedido(1)]);
  assertEquals(ruta.horaFin, null);
  assertExists(ruta.ultimaParada);
});

// Tests de que el request de optimizeTours pase la VALIDACIÓN de Google.
//
// Route Optimization rechaza el request entero —no la parada— si una ventana
// horaria viola sus reglas, y la edge function cae en silencio a computeRoutes.
// Así se estuvo usando el fallback en toda ruta con franjas horarias. Los casos
// salen de los logs de prod (function_logs, "Route Optimization falló"):
//
//   10/10 11:18Z  shipments[0,label=7475] ... outside global time window
//   09/10 17:44Z  shipments[1,label=7284] ... outside global time window
//   09/10 17:43Z  shipments[1,label=7252] ... cost_per_hour_after_soft_end_time
//                 is forbidden if there are more than 1 time window
//
// `erroresDeValidacion` replica las reglas de timeWindows de la referencia de la
// API (ShipmentModel, VisitRequest, TimeWindow). Los tests de abajo arman el
// request con las franjas reales de esos clientes y exigen que no haya errores.
import { assertEquals } from "std/assert/mod.ts";
import {
  construirModeloSingle,
  hhmmDesdeIso,
  optimizeToursMultiPorBarridas,
  optimizeToursPorBarridas,
  type OptimizeToursResponse,
  parseOptimizeTours,
} from "../optimizar-ruta/route-optimization.ts";
import { _resetTokenCache } from "../optimizar-ruta/sa-auth.ts";
import type { PedidoRuta } from "../optimizar-ruta/tramos.ts";

const DEPOSITO = { latitude: -26.8241, longitude: -65.2226 };
const FECHA = "2026-10-10";

function pedido(id: number, lat = -26.8, lng = -65.2): PedidoRuta {
  return { pedido_id: String(id), cliente_nombre: `Cliente ${id}`, latitud: lat, longitud: lng };
}

// deno-lint-ignore no-explicit-any
type Modelo = any;

/**
 * Las reglas de ventanas que Google valida antes de optimizar:
 *  - todo tiempo de una ventana cae dentro de [globalStartTime, globalEndTime];
 *  - `softEndTime` / `costPerHourAfterSoftEndTime` solo con UNA ventana;
 *  - varias ventanas van en orden creciente, disjuntas y NO adyacentes (una
 *    `endTime` sin especificar vale `globalEndTime`).
 * Los mensajes imitan los de la API para que el fallo se lea igual que el log.
 */
function erroresDeValidacion(model: Modelo): string[] {
  const errores: string[] = [];
  const gIni = Date.parse(model.globalStartTime);
  const gFin = Date.parse(model.globalEndTime);
  const fuera = (iso: string) => {
    const t = Date.parse(iso);
    return !(t >= gIni && t <= gFin);
  };

  model.shipments.forEach((s: Modelo, i: number) => {
    s.deliveries.forEach((d: Modelo, j: number) => {
      const tws: Modelo[] = d.timeWindows ?? [];
      const ruta = `shipments[${i},label=${s.label}].deliveries[${j}]`;
      tws.forEach((tw, k) => {
        for (const campo of ["startTime", "endTime", "softStartTime", "softEndTime"]) {
          if (tw[campo] != null && fuera(tw[campo])) {
            errores.push(
              `${ruta}.time_windows[${k}].${campo}: outside global time window (${tw[campo]})`,
            );
          }
        }
        if (tws.length > 1 && (tw.softEndTime != null || tw.costPerHourAfterSoftEndTime != null)) {
          errores.push(
            `${ruta}.time_windows[${k}]: cost_per_hour_after_soft_end_time is forbidden if there are more than 1 time window`,
          );
        }
      });
      for (let k = 0; k < tws.length - 1; k++) {
        const fin = Date.parse(tws[k].endTime ?? model.globalEndTime);
        const ini = Date.parse(tws[k + 1].startTime ?? model.globalStartTime);
        if (!(fin < ini)) {
          errores.push(`${ruta}.time_windows[${k + 1}]: not disjoint, adjacent or out of order`);
        }
      }
    });
  });

  model.vehicles.forEach((v: Modelo, i: number) => {
    for (const tw of v.startTimeWindows ?? []) {
      for (const campo of ["startTime", "endTime"]) {
        if (tw[campo] != null && fuera(tw[campo])) {
          errores.push(
            `vehicles[${i}].start_time_windows.${campo}: outside global time window (${tw[campo]})`,
          );
        }
      }
    }
  });

  return errores;
}

const ventanasDel = (m: Modelo, i = 0) => m.shipments[i].deliveries[0].timeWindows;

// === Casos de los logs ===

Deno.test("caso 7284: el cliente que abre antes de la salida no rompe el request", () => {
  // Abre 07:00 y el camión sale 08:00. La ventana se manda entera: llegar antes
  // de las 08:00 es imposible igual, lo fija el arranque del vehículo.
  const m: Modelo = construirModeloSingle(DEPOSITO, [pedido(7284)], DEPOSITO, {
    fecha: FECHA,
    horaInicio: "08:00",
    ventanas: [{ pedido_id: "7284", franjas: [{ inicio: "07:00", fin: "13:30" }] }],
  });
  assertEquals(erroresDeValidacion(m), []);
  assertEquals(ventanasDel(m)[0].startTime, `${FECHA}T07:00:00-03:00`);
  assertEquals(m.vehicles[0].startTimeWindows[0].startTime, `${FECHA}T08:00:00-03:00`);
});

Deno.test("caso 7475: la barrida que arranca a media mañana acepta al cliente de corrido", () => {
  // 08:00-23:00 cae en la barrida 5, que arranca cuando terminaron las otras.
  const m: Modelo = construirModeloSingle(DEPOSITO, [pedido(7475)], DEPOSITO, {
    fecha: FECHA,
    horaInicio: "11:30",
    horaFinJornada: "18:00",
    ventanas: [{ pedido_id: "7475", franjas: [{ inicio: "08:00", fin: "23:00" }] }],
  });
  assertEquals(erroresDeValidacion(m), []);
  assertEquals(m.vehicles[0].startTimeWindows[0].startTime, `${FECHA}T11:30:00-03:00`);
});

Deno.test("caso 7252: el horario cortado no lleva multa por atraso en ninguna ventana", () => {
  // Decisión del dueño: las franjas anteriores cierran duro (no se entrega en la
  // siesta) y la última abre duro y queda abierta hasta el fin del día.
  const m: Modelo = construirModeloSingle(DEPOSITO, [pedido(7252)], DEPOSITO, {
    fecha: FECHA,
    horaInicio: "08:00",
    horaFinJornada: "18:00",
    ventanas: [{
      pedido_id: "7252",
      franjas: [{ inicio: "08:30", fin: "14:00" }, { inicio: "17:00", fin: "21:00" }],
    }],
  });
  assertEquals(erroresDeValidacion(m), []);
  assertEquals(ventanasDel(m), [
    { startTime: `${FECHA}T08:30:00-03:00`, endTime: `${FECHA}T14:00:00-03:00` },
    { startTime: `${FECHA}T17:00:00-03:00` },
  ]);
});

Deno.test("una sola franja conserva el cierre blando con multa", () => {
  const m: Modelo = construirModeloSingle(DEPOSITO, [pedido(1)], DEPOSITO, {
    fecha: FECHA,
    horaInicio: "08:00",
    ventanas: [{ pedido_id: "1", franjas: [{ inicio: "09:00", fin: "13:00" }] }],
  });
  assertEquals(erroresDeValidacion(m), []);
  const [tw] = ventanasDel(m);
  assertEquals(tw.startTime, `${FECHA}T09:00:00-03:00`);
  assertEquals(tw.softEndTime, `${FECHA}T13:00:00-03:00`);
  assertEquals(tw.costPerHourAfterSoftEndTime > 0, true);
  assertEquals(tw.endTime, undefined);
});

// === Franjas que el editor permite y la API no ===

Deno.test("dos franjas pegadas se fusionan en una (la API rechaza las adyacentes)", () => {
  // validarFranjas (src/utils/horariosCliente.ts) acepta 08-13 y 13-20.
  const m: Modelo = construirModeloSingle(DEPOSITO, [pedido(1)], DEPOSITO, {
    fecha: FECHA,
    horaInicio: "08:00",
    ventanas: [{
      pedido_id: "1",
      franjas: [{ inicio: "08:00", fin: "13:00" }, { inicio: "13:00", fin: "20:00" }],
    }],
  });
  assertEquals(erroresDeValidacion(m), []);
  const tws = ventanasDel(m);
  assertEquals(tws.length, 1);
  assertEquals(tws[0].startTime, `${FECHA}T08:00:00-03:00`);
  assertEquals(tws[0].softEndTime, `${FECHA}T20:00:00-03:00`);
});

Deno.test("las franjas desordenadas se mandan en orden creciente", () => {
  const m: Modelo = construirModeloSingle(DEPOSITO, [pedido(1)], DEPOSITO, {
    fecha: FECHA,
    horaInicio: "08:00",
    horaFinJornada: "18:00",
    ventanas: [{
      pedido_id: "1",
      franjas: [{ inicio: "17:00", fin: "21:00" }, { inicio: "08:30", fin: "14:00" }],
    }],
  });
  assertEquals(erroresDeValidacion(m), []);
  assertEquals(ventanasDel(m)[0].startTime, `${FECHA}T08:30:00-03:00`);
  assertEquals(ventanasDel(m)[1].startTime, `${FECHA}T17:00:00-03:00`);
});

Deno.test("las franjas que se pisan se fusionan", () => {
  // Las etiquetas viejas 'Mañana (08 a 13)' y 'Mediodía (12 a 16)' se pisan.
  const m: Modelo = construirModeloSingle(DEPOSITO, [pedido(1)], DEPOSITO, {
    fecha: FECHA,
    horaInicio: "08:00",
    ventanas: [{
      pedido_id: "1",
      franjas: [{ inicio: "08:00", fin: "13:00" }, { inicio: "12:00", fin: "16:00" }],
    }],
  });
  assertEquals(erroresDeValidacion(m), []);
  const tws = ventanasDel(m);
  assertEquals(tws.length, 1);
  assertEquals(tws[0].softEndTime, `${FECHA}T16:00:00-03:00`);
});

// === Horas de la respuesta: Google las devuelve en UTC ===

Deno.test("hhmmDesdeIso convierte a hora argentina los timestamps UTC de la API", () => {
  // La API devuelve los Timestamp "Z-normalized" aunque el request vaya en -03:00.
  assertEquals(hhmmDesdeIso("2026-10-10T14:30:00Z"), "11:30");
  assertEquals(hhmmDesdeIso("2026-10-10T11:00:00.123456789Z"), "08:00");
  assertEquals(hhmmDesdeIso("2026-10-11T02:59:59Z"), "23:59");
  // Con offset explícito sigue andando.
  assertEquals(hhmmDesdeIso("2026-10-10T12:34:56-03:00"), "12:34");
});

Deno.test("parseOptimizeTours lee la hora estimada y la de fin en hora argentina", () => {
  const ruta = parseOptimizeTours({
    routes: [{
      visits: [{ shipmentLabel: "1", startTime: "2026-10-10T11:12:00Z" }],
      metrics: {},
      vehicleEndTime: "2026-10-10T15:45:00Z",
    }],
  }, [pedido(1)]);
  assertEquals(ruta.ordenOptimizado[0].hora_estimada, "08:12");
  assertEquals(ruta.horaFin, "12:45");
});

// === Punta a punta: lo que de verdad sale hacia Google ===

/** Service account de mentira con una clave RSA real (el token se firma igual). */
async function saDePrueba(): Promise<string> {
  const par = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", par.privateKey));
  let bin = "";
  for (const b of pkcs8) bin += String.fromCharCode(b);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(bin)}\n-----END PRIVATE KEY-----\n`;
  return JSON.stringify({
    client_email: "test@test.iam.gserviceaccount.com",
    private_key: pem,
    project_id: "test",
  });
}

/**
 * Intercepta fetch: el token OAuth y cada optimizeTours. Guarda los modelos que
 * se mandaron y contesta con `responder(modelo)`.
 */
function interceptarGoogle(responder: (model: Modelo) => OptimizeToursResponse) {
  const original = globalThis.fetch;
  const modelos: Modelo[] = [];
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input instanceof Request ? input.url : input);
    if (url.includes("oauth2.googleapis.com")) {
      return Promise.resolve(Response.json({ access_token: "tok", expires_in: 3600 }));
    }
    const model = JSON.parse(String(init?.body)).model;
    modelos.push(model);
    return Promise.resolve(Response.json(responder(model)));
  }) as typeof fetch;
  return { modelos, restore: () => (globalThis.fetch = original) };
}

Deno.test("barridas encadenadas: cada request pasa la validación y arranca a la hora real", async () => {
  _resetTokenCache();
  const sa = await saDePrueba();
  // La barrida 1 termina 11:30 ART, que Google devuelve como 14:30Z.
  const google = interceptarGoogle((model) => ({
    routes: [{
      visits: model.shipments.map((s: Modelo) => ({
        shipmentLabel: s.label,
        startTime: "2026-10-10T12:00:00Z",
      })),
      metrics: { travelDistanceMeters: 1000, totalDuration: "600s" },
      vehicleEndTime: "2026-10-10T14:30:00Z",
    }],
  }));
  try {
    const ruta = await optimizeToursPorBarridas(
      sa,
      DEPOSITO,
      [{ ...pedido(7284), barrida: 2 }, { ...pedido(7475), barrida: 5 }],
      DEPOSITO,
      {
        fecha: FECHA,
        horaInicio: "08:00",
        horaFinJornada: "18:00",
        ventanas: [
          { pedido_id: "7284", franjas: [{ inicio: "07:00", fin: "13:30" }] },
          { pedido_id: "7475", franjas: [{ inicio: "08:00", fin: "23:00" }] },
        ],
      },
    );
    assertEquals(google.modelos.length, 2);
    assertEquals(google.modelos.map(erroresDeValidacion), [[], []]);
    // La barrida 5 sale cuando terminó la 2: 11:30, no 14:30.
    assertEquals(
      google.modelos[1].vehicles[0].startTimeWindows[0].startTime,
      `${FECHA}T11:30:00-03:00`,
    );
    assertEquals(ruta.ordenOptimizado[0].hora_estimada, "09:00");
  } finally {
    google.restore();
  }
});

Deno.test("split multi-repartidor con barridas: los requests pasan la validación", async () => {
  _resetTokenCache();
  const sa = await saDePrueba();
  const google = interceptarGoogle((model) => ({
    routes: model.vehicles.map((v: Modelo, idx: number) => ({
      vehicleLabel: v.label,
      visits: idx === 0
        ? model.shipments.map((s: Modelo) => ({
          shipmentLabel: s.label,
          startTime: "2026-10-10T12:00:00Z",
        }))
        : [],
      metrics: {},
      vehicleEndTime: "2026-10-10T14:30:00Z",
    })),
  }));
  try {
    await optimizeToursMultiPorBarridas(
      sa,
      DEPOSITO,
      [
        { ...pedido(7284), barrida: 2 },
        { ...pedido(7252), barrida: 3 },
        { ...pedido(7475), barrida: 5 },
      ],
      DEPOSITO,
      {
        fecha: FECHA,
        horaInicio: "08:00",
        horaFinJornada: "18:00",
        ventanas: [
          { pedido_id: "7284", franjas: [{ inicio: "07:00", fin: "13:30" }] },
          {
            pedido_id: "7252",
            franjas: [{ inicio: "08:30", fin: "14:00" }, { inicio: "17:00", fin: "21:00" }],
          },
          { pedido_id: "7475", franjas: [{ inicio: "08:00", fin: "23:00" }] },
        ],
      },
      [{ transportista_id: "a" }, { transportista_id: "b" }],
    );
    assertEquals(google.modelos.length, 3);
    assertEquals(google.modelos.map(erroresDeValidacion), [[], [], []]);
    // El chofer "a" encadena: arranca a las 11:30 ART, no a las 14:30.
    assertEquals(
      google.modelos[1].vehicles[0].startTimeWindows[0].startTime,
      `${FECHA}T11:30:00-03:00`,
    );
  } finally {
    google.restore();
  }
});

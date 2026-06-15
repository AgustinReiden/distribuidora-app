// Tests del parseo del tramo de navegación asistida (sin red).
// Import vía el alias std/ del deno.json (ver nota en optimizar_ruta.test.ts).
import { assertEquals, assertThrows } from "std/assert/mod.ts";
import { parseNavTramo, type RoutesResponse } from "../optimizar-ruta/navegar-tramo.ts";

const respuestaOk: RoutesResponse = {
  routes: [
    {
      distanceMeters: 1200,
      duration: "300s",
      polyline: { encodedPolyline: "_overview_" },
      legs: [
        {
          steps: [
            {
              navigationInstruction: { maneuver: "DEPART", instructions: "Dirígete al norte" },
              distanceMeters: 100,
              staticDuration: "30s",
              polyline: { encodedPolyline: "aa" },
              startLocation: { latLng: { latitude: -26.80, longitude: -65.20 } },
              endLocation: { latLng: { latitude: -26.81, longitude: -65.21 } },
            },
            {
              navigationInstruction: { maneuver: "TURN_RIGHT", instructions: "Gira a la derecha" },
              distanceMeters: 1100,
              staticDuration: "270s",
              polyline: { encodedPolyline: "bb" },
              startLocation: { latLng: { latitude: -26.81, longitude: -65.21 } },
              endLocation: { latLng: { latitude: -26.82, longitude: -65.22 } },
            },
          ],
        },
      ],
    },
  ],
};

Deno.test("parseNavTramo extrae pasos, maniobras, geometría y totales", () => {
  const tramo = parseNavTramo(respuestaOk);
  assertEquals(tramo.pasos.length, 2);
  assertEquals(tramo.pasos[0].maniobra, "DEPART");
  assertEquals(tramo.pasos[0].instruccion, "Dirígete al norte");
  assertEquals(tramo.pasos[1].maniobra, "TURN_RIGHT");
  assertEquals(tramo.pasos[1].distancia_metros, 1100);
  assertEquals(tramo.pasos[1].duracion_segundos, 270);
  assertEquals(tramo.pasos[1].inicio, { lat: -26.81, lng: -65.21 });
  assertEquals(tramo.pasos[1].fin, { lat: -26.82, lng: -65.22 });
  assertEquals(tramo.polyline, "_overview_");
  assertEquals(tramo.distancia_metros, 1200);
  assertEquals(tramo.duracion_segundos, 300);
});

Deno.test("parseNavTramo tolera campos faltantes sin romper", () => {
  const tramo = parseNavTramo({
    routes: [{ legs: [{ steps: [{}] }] }],
  });
  assertEquals(tramo.pasos.length, 1);
  assertEquals(tramo.pasos[0].maniobra, "");
  assertEquals(tramo.pasos[0].instruccion, "");
  assertEquals(tramo.pasos[0].inicio, { lat: 0, lng: 0 });
  assertEquals(tramo.polyline, "");
  assertEquals(tramo.distancia_metros, 0);
});

Deno.test("parseNavTramo tira error si no hay ruta", () => {
  assertThrows(() => parseNavTramo({ routes: [] }), Error);
  assertThrows(() => parseNavTramo({}), Error);
});

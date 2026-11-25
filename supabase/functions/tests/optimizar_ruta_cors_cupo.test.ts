// Rut-B14 (ola 3, T3 de #1677): el CORS de optimizar-ruta falla cerrado sin APP_ORIGIN, y
// cada usuario tiene un cupo de llamadas por minuto y por día. Sin red: el cupo recibe la
// llamada a la RPC inyectada.
import { assertEquals, assertStringIncludes } from "std/assert/mod.ts";
import { configCors } from "../optimizar-ruta/cors.ts";
import {
  consumirCupoRuta,
  CUPO_RUTA_POR_DIA,
  CUPO_RUTA_POR_MINUTO,
  type LlamarCupo,
  mensajeCupoRutaAgotado,
} from "../optimizar-ruta/cupo.ts";

// ------------------------------------------------------------------- CORS ---

const desde = (origen: string) => new Request("https://fn.test", { headers: { Origin: origen } });

Deno.test("CORS: con APP_ORIGIN, Allow-Origin es ese origen exacto, con Vary: Origin", () => {
  const c = configCors("https://app.ejemplo.test");
  assertEquals(c.ok, true);
  const h = c.headers(desde("https://app.ejemplo.test"));
  assertEquals(h["Access-Control-Allow-Origin"], "https://app.ejemplo.test");
  assertEquals(h["Vary"], "Origin");
  assertStringIncludes(h["Access-Control-Allow-Headers"], "x-sucursal-id");
  assertEquals(h["Access-Control-Allow-Methods"], "POST, OPTIONS");
});

Deno.test("CORS: una lista separada por comas devuelve el origen pedido si está, y si no el primero", () => {
  const c = configCors("https://app.ejemplo.test, https://staging.ejemplo.test");
  assertEquals(c.ok, true);
  assertEquals(c.headers(desde("https://staging.ejemplo.test"))["Access-Control-Allow-Origin"], "https://staging.ejemplo.test");
  assertEquals(c.headers(desde("https://app.ejemplo.test"))["Access-Control-Allow-Origin"], "https://app.ejemplo.test");
  // Un origen ajeno recibe el primero: el navegador bloquea la respuesta.
  assertEquals(c.headers(desde("https://malo.test"))["Access-Control-Allow-Origin"], "https://app.ejemplo.test");
});

Deno.test("CORS: sin APP_ORIGIN falla cerrado, sin Allow-Origin y con el motivo para el log", () => {
  for (const valor of [undefined, null, "", "   ", " , "]) {
    const c = configCors(valor);
    assertEquals(c.ok, false);
    assertEquals("Access-Control-Allow-Origin" in c.headers(desde("https://app.ejemplo.test")), false);
    if (!c.ok) assertStringIncludes(c.motivo, "APP_ORIGIN");
  }
});

Deno.test('CORS: APP_ORIGIN con "*", solo o en la lista, también falla cerrado', () => {
  for (const valor of ["*", "https://app.ejemplo.test,*"]) {
    const c = configCors(valor);
    assertEquals(c.ok, false);
    assertEquals("Access-Control-Allow-Origin" in c.headers(desde("https://malo.test")), false);
  }
});

Deno.test("CORS: los espacios del secret no entran al header", () => {
  const h = configCors("  https://app.ejemplo.test \n").headers(desde("https://app.ejemplo.test"));
  assertEquals(h["Access-Control-Allow-Origin"], "https://app.ejemplo.test");
});

// ------------------------------------------------------------------- cupo ---

function rpc(respuesta: { data: unknown; error: { message: string } | null }) {
  const llamadas: Array<[number, number]> = [];
  const llamar: LlamarCupo = (m, d) => {
    llamadas.push([m, d]);
    return Promise.resolve(respuesta);
  };
  return { llamar, llamadas };
}

Deno.test("cupo: le pasa a la RPC los topes de la edge y deja pasar si hay lugar", async () => {
  const { llamar, llamadas } = rpc({ data: { ok: true, conteo_dia: 3 }, error: null });
  assertEquals(await consumirCupoRuta(llamar), { ok: true });
  assertEquals(llamadas, [[CUPO_RUTA_POR_MINUTO, CUPO_RUTA_POR_DIA]]);
});

Deno.test("cupo: por minuto y por día frenan con su motivo", async () => {
  assertEquals(
    await consumirCupoRuta(rpc({ data: { ok: false, motivo: "por_minuto", conteo: 21 }, error: null }).llamar),
    { ok: false, motivo: "por_minuto" },
  );
  assertEquals(
    await consumirCupoRuta(rpc({ data: { ok: false, motivo: "por_dia", conteo: 301 }, error: null }).llamar),
    { ok: false, motivo: "por_dia" },
  );
});

Deno.test("cupo: si la RPC falla (o tira), deja pasar: protege el costo, el rol ya se miró", async () => {
  const errorOriginal = console.error;
  console.error = () => {};
  try {
    assertEquals(await consumirCupoRuta(rpc({ data: null, error: { message: "boom" } }).llamar), { ok: true });
    assertEquals(await consumirCupoRuta(() => Promise.reject(new Error("red"))), { ok: true });
  } finally {
    console.error = errorOriginal;
  }
});

Deno.test("cupo: los mensajes dicen qué esperar", () => {
  assertStringIncludes(mensajeCupoRutaAgotado("por_minuto"), "esperá un minuto");
  assertStringIncludes(mensajeCupoRutaAgotado("por_dia"), String(CUPO_RUTA_POR_DIA));
});

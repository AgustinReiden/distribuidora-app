// Paridad del cargo de envío del bot (#1220): la copia de `cargoEnvioPedido`
// en _shared/pricing/cargoEnvio.ts corre los mismos casos que la app
// (src/utils/cargoEnvio.espejo.test.ts) y el SQL (cargo_envio_pedido_puro, vía
// scripts/espejo-cargo-envio.mjs). Si este test falla, el bot le muestra al
// preventista un envío distinto del que cobra el server.
//
// Correr con: deno task test (desde supabase/functions/).

import { assert, assertEquals } from "std/assert/mod.ts";

import {
  cargoEnvioPedido,
  type ModoMinimoPedido,
  motivoRechazoMinimo,
  reglaMinimoDeFila,
} from "../_shared/pricing/cargoEnvio.ts";

const REPO_ROOT = new URL("../../../", import.meta.url).pathname.replace(/^\/([A-Z]:)/, "$1");

interface CasoCargo {
  caso: string;
  total: number;
  regla: {
    modo: ModoMinimoPedido;
    monto_minimo: number;
    monto_envio_gratis: number;
    cargo_envio: number;
  };
  esperado: number;
}

const fixture = JSON.parse(
  await Deno.readTextFile(`${REPO_ROOT}src/utils/cargoEnvio.espejo.json`),
) as { cargo_envio_pedido: CasoCargo[] };

Deno.test("cargoEnvio: el fixture trae casos de cargo_envio_pedido", () => {
  assert(fixture.cargo_envio_pedido.length > 0, "cargo_envio_pedido vacío en el fixture");
});

for (const c of fixture.cargo_envio_pedido) {
  Deno.test(`cargoEnvioPedido (espejo): ${c.caso}`, () => {
    const regla = {
      modo: c.regla.modo,
      montoMinimo: c.regla.monto_minimo,
      montoEnvioGratis: c.regla.monto_envio_gratis,
      cargoEnvio: c.regla.cargo_envio,
    };
    assertEquals(cargoEnvioPedido(c.total, regla), c.esperado);
  });
}

Deno.test("motivoRechazoMinimo: cargo nunca rechaza; escalas y bloquear sí, bajo el mínimo", () => {
  const base = { montoMinimo: 5000, montoEnvioGratis: 15000, cargoEnvio: 500 };
  assertEquals(motivoRechazoMinimo(1000, { ...base, modo: "cargo" }), null);
  assert(motivoRechazoMinimo(4999.99, { ...base, modo: "escalas" }));
  assertEquals(motivoRechazoMinimo(5000, { ...base, modo: "escalas" }), null);
  assert(motivoRechazoMinimo(1000, { ...base, modo: "bloquear" }));
  assertEquals(motivoRechazoMinimo(1000, { ...base, montoMinimo: 0, modo: "bloquear" }), null);
});

Deno.test("reglaMinimoDeFila: sin política o con un modo desconocido = bloquear con todo en 0", () => {
  assertEquals(reglaMinimoDeFila(null), {
    modo: "bloquear",
    montoMinimo: 0,
    montoEnvioGratis: 0,
    cargoEnvio: 0,
  });
  assertEquals(
    reglaMinimoDeFila({
      modo_minimo_pedido: "cargo",
      monto_minimo_pedido: "15000.00",
      monto_envio_gratis: null,
      cargo_envio_pedido: "500.00",
    }),
    { modo: "cargo", montoMinimo: 15000, montoEnvioGratis: 0, cargoEnvio: 500 },
  );
  assertEquals(reglaMinimoDeFila({ modo_minimo_pedido: "otro" }).modo, "bloquear");
});

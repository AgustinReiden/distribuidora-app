// La ventana de 365 días de resolver_preventista corta en el día argentino
// (#1358): entre las 21 y las 24 de Argentina `toISOString()` ya es mañana.

import { assertEquals } from "std/assert/mod.ts";
import { fechaHaceDiasArgentina } from "../_shared/tools/common/resolver_preventista.ts";

Deno.test("fechaHaceDiasArgentina: a las 22:00 ART cuenta desde el día argentino, no el UTC", () => {
  // 22:00 del 2/11/2026 en Argentina = 01:00 UTC del 3/11. El corte UTC daba 2025-11-03.
  const ahora = Date.parse("2026-11-03T01:00:00Z");
  assertEquals(fechaHaceDiasArgentina(365, ahora), "2025-11-02");
});

Deno.test("fechaHaceDiasArgentina: de día coincide con el UTC", () => {
  const ahora = Date.parse("2026-11-03T15:00:00Z");
  assertEquals(fechaHaceDiasArgentina(365, ahora), "2025-11-03");
});

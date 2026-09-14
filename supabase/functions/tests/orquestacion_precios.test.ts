// Tests de `orquestarPrecios` del lado del bot.
//
// Corre EXACTAMENTE los mismos escenarios que la suite de la app
// (src/utils/orquestacionPrecios.test.ts): el fixture está sincronizado byte a
// byte igual que los utils (ver sync_utils.test.ts). Si los dos lados calculan
// distinto, uno de los dos se pone en rojo acá.

import { assertEquals } from "std/assert/mod.ts";
import { orquestarPrecios } from "../_shared/utils/orquestacionPrecios.ts";
import { ESCENARIOS, redondear2 } from "../_shared/utils/orquestacionPrecios.fixture.ts";

for (const escenario of ESCENARIOS) {
  Deno.test(`orquestarPrecios: ${escenario.nombre}`, () => {
    const r = orquestarPrecios(escenario.input);
    const esp = escenario.esperado;

    assertEquals(redondear2(r.totalOriginal), esp.totalOriginal, "totalOriginal");
    assertEquals(
      redondear2(r.totalSinDescuentoCliente),
      esp.totalSinDescuentoCliente,
      "totalSinDescuentoCliente",
    );
    assertEquals(redondear2(r.total), esp.total, "total");

    assertEquals(
      [...r.promoResolucion.productosConPromo].sort(),
      [...esp.productosConPromo].sort(),
      "productosConPromo",
    );
    assertEquals(
      r.promoResolucion.bonificaciones.map((b) => ({
        productoId: String(b.productoId),
        cantidad: b.cantidadBonificacion,
      })),
      esp.bonificaciones,
      "bonificaciones",
    );

    const precios: Record<string, number> = {};
    for (const item of r.items) {
      if (item.esBonificacion) continue;
      precios[String(item.productoId)] = redondear2(item.precioUnitario);
    }
    assertEquals(precios, esp.precioFinalPorProducto, "precio final por producto");
  });
}

Deno.test("orquestarPrecios: sin promos, sin condiciones y sin cliente deja los precios intactos", () => {
  const r = orquestarPrecios({
    items: [{ productoId: "1", cantidad: 3, precioUnitario: 100 }],
  });
  assertEquals(r.total, 300);
  assertEquals(r.totalSinDescuentoCliente, 300);
  assertEquals(r.ahorro, 0);
  assertEquals(r.hayDescuentoPrecios, false);
  assertEquals(r.hayDescuentoCliente, false);
});

Deno.test("orquestarPrecios: etiqueta el origen del descuento (categoría vs general)", () => {
  // Escenario 2: 1 y 2 caen en el general, 3 en una regla por categoría.
  const r = orquestarPrecios(ESCENARIOS[1].input);
  assertEquals(r.descuentoClientePct.get("1"), 10);
  assertEquals(r.descuentoClientePct.get("3"), 0);
  assertEquals(r.descuentoPorCategoria.has("3"), true);
  assertEquals(r.descuentoPorCategoria.has("1"), false);
});

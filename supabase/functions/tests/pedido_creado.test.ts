// Mensaje final de crear_pedido (#1234): desglosa el envío sólo si lo hay.
import { assertEquals, assertStringIncludes } from "std/assert/mod.ts";
import { formatPedidoCreado } from "../telegram-webhook/formatters/pedido-creado.ts";

const nb = (s: string) => s.replace(/ /g, " ");

Deno.test("pedido creado: con envío desglosa Productos + Envío = Total", () => {
  const msg = nb(formatPedidoCreado({ pedido_id: 77, total: 12500, cargo_envio: 500 }));
  assertStringIncludes(msg, "Pedido #77 creado");
  assertStringIncludes(msg, "Productos $ 12.000 + Envío $ 500 = $ 12.500");
});

Deno.test("pedido creado: sin envío queda como siempre", () => {
  for (const d of [{ pedido_id: 5, total: 12000 }, { pedido_id: 5, total: 12000, cargo_envio: 0 }]) {
    const msg = nb(formatPedidoCreado(d));
    assertStringIncludes(msg, "✅ Pedido #5 creado por $ 12.000.");
    assertEquals(msg.includes("Envío"), false);
  }
});

// #1469: la boleta absorbió saldo a favor del cliente al crearse.
Deno.test("pedido creado: con saldo a favor aplicado lo dice", () => {
  const msg = nb(formatPedidoCreado({ pedido_id: 9, total: 12000, cargo_envio: 0, saldo_a_favor_aplicado: 400 }));
  assertStringIncludes(msg, "✅ Pedido #9 creado por $ 12.000.");
  assertStringIncludes(msg, "Saldo a favor aplicado: $ 400.");
});

Deno.test("pedido creado: sin saldo a favor no lo menciona", () => {
  const msg = nb(formatPedidoCreado({ pedido_id: 9, total: 12000, saldo_a_favor_aplicado: 0 }));
  assertEquals(msg.includes("Saldo a favor"), false);
});

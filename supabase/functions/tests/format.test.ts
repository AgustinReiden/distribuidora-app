// Tests para los format helpers visuales (_shared/format.ts).
//
// Cubrimos:
//   * header: shape (emoji opcional + uppercase + bold + divider).
//   * divider: 14 chars de ━.
//   * bullet: prefijo emoji opcional, sin escape (caller responsable).
//   * statusBadge: 5 estados.
//   * kvRow: escape MV2 de label y value.
//   * kvRowRaw: escape solo de label.
//   * Sanity de re-exports (formatCurrency, formatFechaCorta, escapeMarkdownV2).

import { assert, assertEquals } from "std/assert/mod.ts";
import {
  bullet,
  divider,
  escapeMarkdownV2,
  formatCurrency,
  formatFechaCorta,
  header,
  kvRow,
  kvRowRaw,
  statusBadge,
} from "../_shared/format.ts";

// ----------------------------------------------------------------------------
// header
// ----------------------------------------------------------------------------

Deno.test("header con emoji: prefijo emoji + bold + divider (preserva casing)", () => {
  const out = header("Ventas", "📊");
  assertEquals(out, "📊 *Ventas*\n━━━━━━━━━━━━━━");
});

Deno.test("header sin emoji: omite prefijo", () => {
  const out = header("Ventas", undefined);
  assertEquals(out, "*Ventas*\n━━━━━━━━━━━━━━");
});

Deno.test("header escapa caracteres MV2 reservados en el texto", () => {
  // "Top.Clientes" tiene un punto reservado en MV2 — debe escaparse.
  const out = header("Top.Clientes", "🏪");
  assertEquals(out, "🏪 *Top\\.Clientes*\n━━━━━━━━━━━━━━");
});

Deno.test("header NO uppercase automático (caller decide)", () => {
  // Si el caller quiere uppercase, lo pasa explícitamente.
  const out = header("VENTAS", "📊");
  assertEquals(out, "📊 *VENTAS*\n━━━━━━━━━━━━━━");
});

// ----------------------------------------------------------------------------
// divider
// ----------------------------------------------------------------------------

Deno.test("divider: 14 chars de ━", () => {
  const out = divider();
  assertEquals(out, "━━━━━━━━━━━━━━");
  assertEquals(out.length, 14);
});

// ----------------------------------------------------------------------------
// bullet
// ----------------------------------------------------------------------------

Deno.test("bullet sin emoji: '•  text' (dos espacios)", () => {
  assertEquals(bullet("Stock bajo"), "•  Stock bajo");
});

Deno.test("bullet con emoji: '•  EMOJI text'", () => {
  assertEquals(bullet("Coca 2L", "📦"), "•  📦 Coca 2L");
});

Deno.test("bullet NO escapa el texto (caller responsable)", () => {
  // El caller pasa texto pre-escapado (ej. con bold MV2). bullet lo deja pasar.
  assertEquals(bullet("*Coca 2L* \\| $850"), "•  *Coca 2L* \\| $850");
});

// ----------------------------------------------------------------------------
// statusBadge
// ----------------------------------------------------------------------------

Deno.test("statusBadge mapea cada kind a su emoji", () => {
  assertEquals(statusBadge("ok"), "✅");
  assertEquals(statusBadge("warn"), "⚠️");
  assertEquals(statusBadge("err"), "❌");
  assertEquals(statusBadge("pending"), "⏳");
  assertEquals(statusBadge("info"), "💡");
});

// ----------------------------------------------------------------------------
// kvRow
// ----------------------------------------------------------------------------

Deno.test("kvRow: label bold + value escapado", () => {
  // Saldo "$12.500" tiene punto reservado MV2 → escape.
  assertEquals(
    kvRow("Saldo", "$12.500"),
    "*Saldo:* $12\\.500",
  );
});

Deno.test("kvRow: escape de chars en label", () => {
  assertEquals(
    kvRow("Total (ARS)", "12345"),
    "*Total \\(ARS\\):* 12345",
  );
});

// ----------------------------------------------------------------------------
// kvRowRaw
// ----------------------------------------------------------------------------

Deno.test("kvRowRaw: NO escapa el value (caller pasó pre-escapado)", () => {
  // Caller ya escapó el value y le puso bold con MV2.
  assertEquals(
    kvRowRaw("Saldo", "*$12\\.500*"),
    "*Saldo:* *$12\\.500*",
  );
});

// ----------------------------------------------------------------------------
// Sanity de re-exports (no testeamos exhaustivamente — esos helpers ya tienen
// sus propios tests en otro archivo; solo confirmamos que están accesibles).
// ----------------------------------------------------------------------------

Deno.test("re-exports: formatCurrency funciona", () => {
  // Es un sanity: solo confirmamos que la función está y produce un string.
  const out = formatCurrency(12500);
  assert(out.includes("12.500"), `currency debería incluir 12.500: ${out}`);
});

Deno.test("re-exports: formatFechaCorta y escapeMarkdownV2 disponibles", () => {
  assertEquals(formatFechaCorta(null), "—");
  assertEquals(escapeMarkdownV2("a.b"), "a\\.b");
});

// Piezas puras de las issues #1309 y #1311 del bot de Telegram.
//
//   * relojDigest: la fecha resumida (ayer), hoy, la hora y el día ISO de una
//     corrida del digest, siempre en TZ Argentina (#1309).
//   * partirMensaje / sendMessage: una respuesta de más de 4096 caracteres sale
//     en varios mensajes y el teclado va sólo en el último (#1311).
//   * costoTranscripcionUsd: lo que cuesta un audio, para el techo del mes (#1311).
//
// Los flujos del webhook (voz, canje, cancelar pedido) están en
// telegram-webhook.test.ts; los del digest, en digest*.test.ts y
// aviso_atrasados.test.ts.

import { assert, assertAlmostEquals, assertEquals } from "std/assert/mod.ts";

import { relojDigest } from "../telegram-digest/reloj.ts";
import { partirMensaje, sendMessage, TELEGRAM_MAX_TEXTO } from "../_shared/telegram.ts";
import { costoTranscripcionUsd } from "../_shared/llm/modelo.ts";

// ============================================================================
// relojDigest
// ============================================================================

Deno.test("relojDigest: a las 02:30 UTC todavía es el día anterior en Argentina", () => {
  // 2026-10-30 02:30 UTC = 2026-10-29 23:30 en Argentina (UTC-3), jueves.
  const r = relojDigest(new Date("2026-10-30T02:30:00Z"));
  assertEquals(r.hoy, "2026-10-29");
  assertEquals(r.fecha, "2026-10-28");
  assertEquals(r.hora, 23);
  assertEquals(r.dow, 4);
});

Deno.test("relojDigest: a las 00:10 del lunes (03:10 UTC) la hora es 0, no 24, y el día es lunes", () => {
  // 2026-11-02 03:10 UTC = 2026-11-02 00:10 en Argentina, lunes.
  const r = relojDigest(new Date("2026-11-02T03:10:00Z"));
  assertEquals(r.hoy, "2026-11-02");
  assertEquals(r.hora, 0);
  assertEquals(r.dow, 1);
  // Ayer cruza de mes: el resumen es del domingo 1/11.
  assertEquals(r.fecha, "2026-11-01");
});

Deno.test("relojDigest: el 1/1 resume el 31/12 del año anterior", () => {
  const r = relojDigest(new Date("2027-01-01T15:00:00Z"));
  assertEquals(r.hoy, "2027-01-01");
  assertEquals(r.fecha, "2026-12-31");
  assertEquals(r.hora, 12);
  // 2027-01-01 es viernes.
  assertEquals(r.dow, 5);
});

Deno.test("relojDigest: el domingo es 7 (ISO), no 0", () => {
  // 2026-11-01 es domingo.
  assertEquals(relojDigest(new Date("2026-11-01T15:00:00Z")).dow, 7);
});

Deno.test("relojDigest: la fecha y la hora salen del mismo instante", () => {
  // Justo antes y justo después de la medianoche argentina (03:00 UTC): la
  // fecha resumida y la hora cambian juntas, nunca una de un día y la otra del
  // siguiente.
  const antes = relojDigest(new Date("2026-10-30T02:59:59Z"));
  const despues = relojDigest(new Date("2026-10-30T03:00:00Z"));
  assertEquals([antes.hoy, antes.fecha, antes.hora], ["2026-10-29", "2026-10-28", 23]);
  assertEquals([despues.hoy, despues.fecha, despues.hora], ["2026-10-30", "2026-10-29", 0]);
});

// ============================================================================
// partirMensaje
// ============================================================================

/** Hay un medio emoji (pareja sustituta cortada) en el texto. */
function tieneSustitutoSuelto(s: string): boolean {
  return /[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/.test(s);
}

Deno.test("partirMensaje: un texto corto es una sola parte, intacta", () => {
  assertEquals(partirMensaje("hola"), ["hola"]);
  assertEquals(partirMensaje(""), [""]);
  const justo = "x".repeat(TELEGRAM_MAX_TEXTO);
  assertEquals(partirMensaje(justo), [justo]);
});

Deno.test("partirMensaje: 10.000 caracteres con saltos de línea → partes ≤ 4096 que reconstruyen el texto", () => {
  const lineas: string[] = [];
  for (let i = 1; lineas.join("\n").length < 10_000; i++) {
    lineas.push(`${i}. Cliente número ${i} — Av. Siempreviva ${i * 7}, 12 días sin comprar`);
  }
  const texto = lineas.join("\n");
  assert(texto.length >= 10_000);

  const partes = partirMensaje(texto);
  assert(partes.length >= 3, `10.000 caracteres son al menos 3 partes (${partes.length})`);
  for (const p of partes) {
    assert(p.length <= TELEGRAM_MAX_TEXTO, `una parte mide ${p.length}`);
    assert(p.length > 0);
  }
  // Se corta en un salto de línea, que es el separador que se consume.
  assertEquals(partes.join("\n"), texto);
  // Y ninguna línea queda partida a la mitad.
  for (const p of partes) {
    for (const linea of p.split("\n")) assert(lineas.includes(linea), `línea partida: ${linea}`);
  }
});

Deno.test("partirMensaje: sin saltos pero con espacios corta en un espacio", () => {
  const palabras = Array.from({ length: 2000 }, (_, i) => `palabra${i}`);
  const texto = palabras.join(" ");
  const partes = partirMensaje(texto);
  assert(partes.length >= 2);
  for (const p of partes) assert(p.length <= TELEGRAM_MAX_TEXTO);
  assertEquals(partes.join(" "), texto);
});

Deno.test("partirMensaje: sin saltos ni espacios corta en seco en 4096", () => {
  const texto = "a".repeat(10_000);
  const partes = partirMensaje(texto);
  assertEquals(partes.map((p) => p.length), [4096, 4096, 1808]);
  assertEquals(partes.join(""), texto);
});

Deno.test("partirMensaje: el corte en seco no parte un emoji (pareja sustituta)", () => {
  // El 😀 ocupa dos unidades UTF-16: con 4095 'a' delante, el corte en 4096
  // caería en medio de la pareja.
  const texto = "a".repeat(4095) + "😀".repeat(5);
  assertEquals(texto.charCodeAt(4095) >= 0xd800 && texto.charCodeAt(4095) <= 0xdbff, true);
  const partes = partirMensaje(texto);
  assert(partes.length >= 2);
  for (const p of partes) {
    assert(p.length <= TELEGRAM_MAX_TEXTO);
    assert(!tieneSustitutoSuelto(p), "una parte tiene un emoji partido");
  }
  assertEquals(partes[0].length, 4095);
  assertEquals(partes.join(""), texto);
});

Deno.test("partirMensaje: respeta un máximo distinto del default", () => {
  assertEquals(partirMensaje("uno dos tres", 7), ["uno dos", "tres"]);
});

// ============================================================================
// sendMessage con un texto largo
// ============================================================================

function stubTelegram() {
  const original = globalThis.fetch;
  const calls: Array<{ url: string; body: Record<string, unknown> }> = [];
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), body: JSON.parse(String(init?.body)) });
    return Promise.resolve(
      new Response(JSON.stringify({ ok: true, result: { message_id: calls.length } }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
  }) as typeof fetch;
  Deno.env.set("TELEGRAM_BOT_TOKEN", "test-token");
  return {
    calls,
    restore: () => {
      globalThis.fetch = original;
      Deno.env.delete("TELEGRAM_BOT_TOKEN");
    },
  };
}

const TECLADO = { inline_keyboard: [[{ text: "🧾 Cliente", callback_data: "v1:visita:1" }]] };

Deno.test("sendMessage: un texto largo sale en varios mensajes y el teclado va sólo en el último", async () => {
  const f = stubTelegram();
  try {
    const texto = Array.from({ length: 300 }, (_, i) => `Línea ${i} ${"x".repeat(40)}`).join("\n");
    assert(texto.length > 2 * TELEGRAM_MAX_TEXTO);

    await sendMessage(77, texto, { reply_markup: TECLADO, parse_mode: undefined });

    const envios = f.calls.filter((c) => c.url.endsWith("/sendMessage"));
    assert(envios.length >= 3, `debió partir en varios envíos (${envios.length})`);
    assertEquals(envios.length, partirMensaje(texto).length);
    for (const e of envios) {
      assertEquals(e.body.chat_id, 77);
      assert(String(e.body.text).length <= TELEGRAM_MAX_TEXTO);
    }
    // En orden, y juntos reconstruyen el texto.
    assertEquals(envios.map((e) => String(e.body.text)).join("\n"), texto);
    // El teclado, sólo en el último: debajo de todo el texto.
    envios.slice(0, -1).forEach((e, i) =>
      assertEquals(e.body.reply_markup, undefined, `el envío ${i} no debía llevar teclado`)
    );
    assertEquals(envios.at(-1)!.body.reply_markup, TECLADO);
  } finally {
    f.restore();
  }
});

Deno.test("sendMessage: un texto largo conserva las otras opciones (parse_mode) en cada parte", async () => {
  const f = stubTelegram();
  try {
    const texto = "y".repeat(5000) + " " + "z".repeat(5000);
    await sendMessage(5, texto, { parse_mode: "MarkdownV2" });
    const envios = f.calls.filter((c) => c.url.endsWith("/sendMessage"));
    assert(envios.length >= 2);
    for (const e of envios) assertEquals(e.body.parse_mode, "MarkdownV2");
  } finally {
    f.restore();
  }
});

Deno.test("sendMessage: un texto corto con teclado sigue siendo un solo envío con el teclado", async () => {
  const f = stubTelegram();
  try {
    await sendMessage(77, "hola", { reply_markup: TECLADO });
    assertEquals(f.calls.length, 1);
    assertEquals(f.calls[0].body.text, "hola");
    assertEquals(f.calls[0].body.reply_markup, TECLADO);
  } finally {
    f.restore();
  }
});

// ============================================================================
// costoTranscripcionUsd
// ============================================================================

Deno.test("costoTranscripcionUsd: 60 s de gemini cuestan 0,003", () => {
  assertAlmostEquals(costoTranscripcionUsd("gemini", 60), 0.003, 1e-12);
  assertAlmostEquals(costoTranscripcionUsd("gemini", 30), 0.0015, 1e-12);
});

Deno.test("costoTranscripcionUsd: openai 0,006/min y groq 0,04/hora", () => {
  assertAlmostEquals(costoTranscripcionUsd("openai", 60), 0.006, 1e-12);
  assertAlmostEquals(costoTranscripcionUsd("groq", 60), 0.04 / 60, 1e-12);
  assertAlmostEquals(costoTranscripcionUsd("groq", 3600), 0.04, 1e-12);
});

Deno.test("costoTranscripcionUsd: un proveedor desconocido paga el mayor de los conocidos", () => {
  const mayor = Math.max(
    costoTranscripcionUsd("gemini", 60),
    costoTranscripcionUsd("openai", 60),
    costoTranscripcionUsd("groq", 60),
  );
  assertAlmostEquals(costoTranscripcionUsd("whisper-de-juancito", 60), mayor, 1e-12);
  assertAlmostEquals(costoTranscripcionUsd("", 60), mayor, 1e-12);
  assertAlmostEquals(costoTranscripcionUsd("whisper-de-juancito", 60), 0.006, 1e-12);
});

Deno.test("costoTranscripcionUsd: segundos negativos o cero valen 0", () => {
  assertEquals(costoTranscripcionUsd("gemini", -30), 0);
  assertEquals(costoTranscripcionUsd("openai", -1), 0);
  assertEquals(costoTranscripcionUsd("desconocido", -1000), 0);
  assertEquals(costoTranscripcionUsd("gemini", 0), 0);
});

Deno.test("partirMensaje: un texto que termina en el salto donde se corta no deja un pedazo vacío", () => {
  for (const texto of ["a".repeat(4096) + "\n", "a".repeat(4095) + "\n\n", "a".repeat(4096) + "\n \n"]) {
    const partes = partirMensaje(texto);
    assertEquals(partes.length, 1, `${JSON.stringify(texto.slice(-4))}: ${partes.map((p) => p.length)}`);
    assert(partes.every((p) => p.trim() !== ""));
  }
});

Deno.test("partirMensaje: el corte en seco no parte un escape de MarkdownV2", () => {
  const texto = "a".repeat(4095) + "\." + "b".repeat(10);
  const partes = partirMensaje(texto);
  assertEquals(partes[0].endsWith("\\"), false, "el pedazo no puede terminar en una barra suelta");
  assertEquals(partes.join(""), texto);
});

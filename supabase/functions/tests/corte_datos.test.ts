// Tests de la línea "🕒 Datos al" (#971): la agrega el código con el
// `consulta_realizada_at` real de la tool, nunca el modelo.
// Correr con: deno task test (desde supabase/functions/).

import { assertEquals, assertStringIncludes } from "std/assert/mod.ts";
import type { SupabaseClient } from "@supabase/supabase-js";

import { runAgent } from "../_shared/gemini/agent.ts";
import { aplicarCorteDatos, extraerCorte } from "../_shared/gemini/corte-datos.ts";
import { clearSystemPromptCache, setSystemPromptForTests } from "../_shared/gemini/prompts/base.ts";
import {
  _clearToolsForTests,
  _resetRegisterFlagForTests,
  registerTool,
} from "../_shared/tools/index.ts";
import type { Tool } from "../_shared/tools/base.ts";
import { _setServiceRoleClientForTests } from "../_shared/supabase.ts";
import type { BotUser } from "../_shared/types.ts";

// ============================================================================
// Funciones puras
// ============================================================================

Deno.test("extraerCorte: sólo un string no vacío en consulta_realizada_at", () => {
  assertEquals(
    extraerCorte({ consulta_realizada_at: "07/10/2026, 11:02 (ART)" }),
    "07/10/2026, 11:02 (ART)",
  );
  assertEquals(extraerCorte({ total: 1 }), undefined);
  assertEquals(extraerCorte({ consulta_realizada_at: "" }), undefined);
  assertEquals(extraerCorte({ consulta_realizada_at: 123 }), undefined);
  assertEquals(extraerCorte(null), undefined);
  assertEquals(extraerCorte([1, 2]), undefined);
});

Deno.test("aplicarCorteDatos: sin corte real borra la línea inventada por el modelo", () => {
  const texto = "📊 Ventas por preventista\n• Juan: $100.000\n\n🕒 Datos al 2026-07-23 15:00:00";
  assertEquals(aplicarCorteDatos(texto, undefined), "📊 Ventas por preventista\n• Juan: $100.000");
});

Deno.test("aplicarCorteDatos: con corte real reemplaza la del modelo por la verdadera", () => {
  const texto = "📊 Ventas\n• Total: $5\n\n🕒 Datos al 2026-07-23 15:00:00\n";
  assertEquals(
    aplicarCorteDatos(texto, "07/10/2026, 11:02 (ART)"),
    "📊 Ventas\n• Total: $5\n\n🕒 Datos al 07/10/2026, 11:02 (ART)",
  );
});

Deno.test("aplicarCorteDatos: borra variantes sin emoji o con otro reloj, en el medio del texto", () => {
  const texto = "A\nDatos al ayer\nB\n  ⏰ datos al 1/1\nC";
  assertEquals(aplicarCorteDatos(texto, undefined), "A\n\nB\n\nC");
});

Deno.test("aplicarCorteDatos: no toca un texto sin línea de corte", () => {
  assertEquals(
    aplicarCorteDatos("Los datos al día de hoy: $5", undefined),
    "Los datos al día de hoy: $5",
  );
});

// ============================================================================
// runAgent end-to-end (Gemini y Supabase mockeados)
// ============================================================================

function mockSupabase(): SupabaseClient {
  // deno-lint-ignore no-explicit-any
  const builder: any = {
    select: () => builder,
    eq: () => builder,
    maybeSingle: () => Promise.resolve({ data: null, error: null }),
    upsert: () => Promise.resolve({ error: null }),
    insert: () => Promise.resolve({ error: null }),
  };
  // deno-lint-ignore no-explicit-any
  const client: any = {
    from: () => builder,
    rpc: () => Promise.resolve({ data: null, error: null }),
  };
  return client as SupabaseClient;
}

function geminiResp(parts: unknown[]): Record<string, unknown> {
  return {
    candidates: [{ content: { role: "model", parts }, finishReason: "STOP" }],
    usageMetadata: { totalTokenCount: 10 },
  };
}

async function correrTurno(
  toolData: Record<string, unknown>,
  textoModelo: string,
): Promise<string> {
  Deno.env.set("GEMINI_API_KEY", "test-key");
  clearSystemPromptCache();
  setSystemPromptForTests("admin", "TEST_PROMPT_ADMIN");
  _clearToolsForTests();
  _resetRegisterFlagForTests();
  const client = mockSupabase();
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const tool: Tool<Record<string, never>, Record<string, unknown>> = {
    name: "reporte_fake",
    description: "test tool",
    parameters: { type: "object", properties: {} },
    allowedRoles: ["admin"],
    handler: () => Promise.resolve(toolData),
  };
  registerTool(tool);

  const queue = [
    geminiResp([{ functionCall: { name: "reporte_fake", args: {} } }]),
    geminiResp([{ text: textoModelo }]),
  ];
  const original = globalThis.fetch;
  globalThis.fetch = (() =>
    Promise.resolve(
      new Response(JSON.stringify(queue.shift()), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    )) as typeof fetch;

  const user: BotUser = {
    telegram_user_id: 42,
    perfil_id: "11111111-1111-1111-1111-111111111111",
    rol: "admin",
    sucursal_id: 1,
    activo: true,
  };
  try {
    const result = await runAgent({
      supabase: client,
      user,
      telegram_user_id: 42,
      userMessage: "cuánto vendió el mejor preventista en septiembre",
    });
    return result.text;
  } finally {
    globalThis.fetch = original;
    Deno.env.delete("GEMINI_API_KEY");
    clearSystemPromptCache();
    _clearToolsForTests();
    _resetRegisterFlagForTests();
    _setServiceRoleClientForTests(null);
  }
}

Deno.test("runAgent: tool sin consulta_realizada_at → el 'Datos al' inventado no llega al usuario", async () => {
  // Caso de prod del 2026-10-07: ventas_por_preventista no devuelve el campo
  // y el modelo cerró con un corte de julio.
  const text = await correrTurno(
    { preventistas: [{ nombre: "Juan", total: 100000 }] },
    "📊 Top preventista septiembre\n• Juan: $100.000\n\n🕒 Datos al 2026-07-23 15:00:00",
  );
  assertEquals(text, "📊 Top preventista septiembre\n• Juan: $100.000");
});

Deno.test("runAgent: tool con consulta_realizada_at → la línea sale del valor real", async () => {
  const text = await correrTurno(
    { total_ventas: 5, consulta_realizada_at: "07/10/2026, 11:02 (ART)" },
    "📊 Ventas\n• Total: $5\n\n🕒 Datos al 2026-07-23 15:00:00",
  );
  assertStringIncludes(text, "🕒 Datos al 07/10/2026, 11:02 (ART)");
  assertEquals(text.includes("2026-07-23"), false);
  assertEquals(text.endsWith("🕒 Datos al 07/10/2026, 11:02 (ART)"), true);
});

// #979 (PR 3a): capa de proveedor, costo, techo de gasto, respuestas paralelas
// agrupadas, memoria compacta y orden del prompt.
//
// Lo que más importa:
//   * el adaptador de OpenAI arma tool_calls y tool messages que se
//     corresponden (si no, OpenAI rechaza la request entera);
//   * el costo de cada respuesta incluye el razonamiento y la caché;
//   * con el mes agotado el agente pasa al modelo barato o a sólo comandos,
//     sin llamar a ningún modelo;
//   * las respuestas a llamadas paralelas van en UN turno (Gemini 3.x).

import { assert, assertEquals, assertRejects, assertStringIncludes } from "std/assert/mod.ts";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  costoUsd,
  MODELO_DEFAULT,
  modeloActivo,
  precioDe,
  proveedorDe,
} from "../_shared/llm/modelo.ts";
import {
  aChatCompletions,
  callOpenAI,
  deChatCompletions,
  reasoningEffortDefault,
} from "../_shared/llm/openai.ts";
import { generar, razonamientoGemini } from "../_shared/llm/index.ts";
import {
  decidirModelo,
  estadoPresupuesto,
  MENSAJE_SOLO_BOTONES,
  registrarCosto,
  textoAviso,
} from "../_shared/llm/presupuesto.ts";
import { runAgent } from "../_shared/gemini/agent.ts";
import { compactarRespuestas, MAX_CHARS_RESULTADO_EN_MEMORIA } from "../_shared/gemini/memory.ts";
import { appendFunctionResponses } from "../_shared/gemini/history-mapper.ts";
import type { GeminiContent, GeminiGenerateContentRequest } from "../_shared/gemini/types.ts";
import {
  clearSystemPromptCache,
  getSystemPrompt,
  setSystemPromptForTests,
} from "../_shared/gemini/prompts/base.ts";
import { _clearToolsForTests, _resetRegisterFlagForTests, registerTool } from "../_shared/tools/index.ts";
import type { Tool } from "../_shared/tools/base.ts";
import { _setServiceRoleClientForTests } from "../_shared/supabase.ts";
import type { BotUser } from "../_shared/types.ts";

// ============================================================================
// Helpers
// ============================================================================

const ENV_LLM = [
  "BOT_LLM_MODEL",
  "GEMINI_MODEL",
  "BOT_LLM_MODEL_FALLBACK",
  "BOT_THINKING_BUDGET",
  "BOT_THINKING_LEVEL",
  "BOT_REASONING_EFFORT",
  "OPENAI_API_KEY",
  "OPENAI_BASE_URL",
  "GEMINI_API_KEY",
  "TELEGRAM_BOT_TOKEN",
];

function limpiarEnv() {
  for (const k of ENV_LLM) Deno.env.delete(k);
}

function conEnv(vars: Record<string, string>, fn: () => void | Promise<void>) {
  return async () => {
    limpiarEnv();
    for (const [k, v] of Object.entries(vars)) Deno.env.set(k, v);
    try {
      await fn();
    } finally {
      limpiarEnv();
    }
  };
}

interface Llamada {
  url: string;
  headers: Headers;
  body: Record<string, unknown> | null;
}

/** fetch falso: `responder` decide por URL. Guarda cada llamada. */
function stubFetch(responder: (url: string, n: number) => Response) {
  const original = globalThis.fetch;
  const llamadas: Llamada[] = [];
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    llamadas.push({
      url,
      headers: new Headers(init?.headers),
      body: init?.body ? JSON.parse(init.body as string) : null,
    });
    return Promise.resolve(responder(url, llamadas.length));
  }) as typeof fetch;
  return { llamadas, restore: () => (globalThis.fetch = original) };
}

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

const geminiTexto = (text: string, usage: Record<string, number> = { totalTokenCount: 10 }) => ({
  candidates: [{ content: { role: "model", parts: [{ text }] }, finishReason: "STOP" }],
  usageMetadata: usage,
});

const openaiTexto = (content: string) => ({
  choices: [{ message: { role: "assistant", content }, finish_reason: "stop" }],
  usage: { prompt_tokens: 1000, completion_tokens: 100, total_tokens: 1100 },
});

// ============================================================================
// 1. Modelo y precios
// ============================================================================

Deno.test("proveedorDe: gpt-* y o<n> van a OpenAI, el resto a Gemini", () => {
  assertEquals(proveedorDe("gpt-6-luna"), "openai");
  assertEquals(proveedorDe("o4-mini"), "openai");
  assertEquals(proveedorDe("gemini-2.5-flash"), "gemini");
  assertEquals(proveedorDe("gemini-3.5-flash-lite"), "gemini");
});

Deno.test("precioDe: flash-lite no se cobra como flash, y lo desconocido se cobra caro", () => {
  assertEquals(precioDe("gemini-2.5-flash-lite").precio.salida, 0.40);
  assertEquals(precioDe("gemini-2.5-flash").precio.salida, 2.50);
  assertEquals(precioDe("gpt-6-luna-2026-09").precio.entrada, 0.10);
  const raro = precioDe("modelo-que-no-existe");
  assertEquals(raro.conocido, false);
  // Equivocarse para arriba adelanta el aviso; para abajo, lo pasa de largo.
  assertEquals(raro.precio.salida, 2.50);
});

Deno.test("costoUsd: la entrada cacheada cuesta un 90% menos y la salida incluye razonamiento", () => {
  // gemini-2.5-flash: 0,30 / 0,03 / 2,50 por millón.
  const c = costoUsd("gemini-2.5-flash", { entrada: 10_000, entradaCacheada: 4_000, salida: 1_000 });
  // 6000*0,30 + 4000*0,03 + 1000*2,50 = 1800 + 120 + 2500 = 4420 / 1e6
  assertEquals(c.toFixed(6), "0.004420");
});

Deno.test("modeloActivo: BOT_LLM_MODEL, si no GEMINI_MODEL, si no el de siempre", conEnv({}, () => {
  assertEquals(modeloActivo(), MODELO_DEFAULT);
  Deno.env.set("GEMINI_MODEL", "gemini-2.5-flash-lite");
  assertEquals(modeloActivo(), "gemini-2.5-flash-lite");
  Deno.env.set("BOT_LLM_MODEL", " gpt-6-luna ");
  assertEquals(modeloActivo(), "gpt-6-luna");
}));

Deno.test("razonamientoGemini: 512 por defecto en 2.5, configurable, y nada en 3.x sin variable", conEnv({}, () => {
  assertEquals(razonamientoGemini("gemini-2.5-flash"), { thinkingBudget: 512 });
  Deno.env.set("BOT_THINKING_BUDGET", "0");
  assertEquals(razonamientoGemini("gemini-2.5-flash"), { thinkingBudget: 0 });
  Deno.env.set("BOT_THINKING_BUDGET", "-1");
  assertEquals(razonamientoGemini("gemini-2.5-flash"), undefined);
  // Un typo no deja el razonamiento libre (el caro): vuelve a 512.
  Deno.env.set("BOT_THINKING_BUDGET", "mil");
  assertEquals(razonamientoGemini("gemini-2.5-flash"), { thinkingBudget: 512 });
  assertEquals(razonamientoGemini("gemini-3.5-flash-lite"), undefined);
  // Flash-Lite (el modelo barato del techo) no razona: no se lo enciende.
  assertEquals(razonamientoGemini("gemini-2.5-flash-lite"), undefined);
  Deno.env.set("BOT_THINKING_LEVEL", "low");
  assertEquals(razonamientoGemini("gemini-3.5-flash-lite"), { thinkingLevel: "low" });
  // Un parámetro de 3.x no se le manda a un 2.5.
  assertEquals(razonamientoGemini("gemini-2.5-flash-lite"), undefined);
}));

// ============================================================================
// 2. Adaptador de OpenAI
// ============================================================================

const REQ_CON_PARALELAS: GeminiGenerateContentRequest = {
  system_instruction: { parts: [{ text: "SOS UN BOT" }] },
  contents: [
    { role: "user", parts: [{ text: "stock de manaos y de placer" }] },
    {
      role: "model",
      parts: [
        { functionCall: { name: "stock_y_ventas", args: { texto: "manaos" } } },
        { functionCall: { name: "stock_y_ventas", args: { texto: "placer" } } },
      ],
    },
    {
      role: "user",
      parts: [
        { functionResponse: { name: "stock_y_ventas", response: { result: { n: 1 } } } },
        { functionResponse: { name: "stock_y_ventas", response: { result: { n: 2 } } } },
      ],
    },
  ],
  tools: [{
    function_declarations: [{
      name: "stock_y_ventas",
      description: "stock",
      parameters: { type: "object", properties: { texto: { type: "string" } } },
    }],
  }],
  tool_config: { function_calling_config: { mode: "AUTO" } },
  generationConfig: { temperature: 0.3, maxOutputTokens: 2048 },
};

Deno.test("aChatCompletions: cada respuesta apunta al id de SU llamada, en orden", () => {
  const body = aChatCompletions(REQ_CON_PARALELAS, "gpt-6-luna");
  // deno-lint-ignore no-explicit-any
  const msgs = body.messages as any[];
  assertEquals(msgs.map((m) => m.role), ["system", "user", "assistant", "tool", "tool"]);
  assertEquals(msgs[0].content, "SOS UN BOT");
  assertEquals(msgs[2].tool_calls.map((t: { id: string }) => t.id), ["c1_0", "c1_1"]);
  assertEquals(JSON.parse(msgs[2].tool_calls[1].function.arguments), { texto: "placer" });
  assertEquals(msgs[3].tool_call_id, "c1_0");
  assertEquals(JSON.parse(msgs[3].content), { result: { n: 1 } });
  assertEquals(msgs[4].tool_call_id, "c1_1");
  assertEquals(body.tool_choice, "auto");
  // El razonamiento sale del mismo tope en OpenAI: se duplica, piso 4096.
  assertEquals(body.max_completion_tokens, 4096);
  // deno-lint-ignore no-explicit-any
  assertEquals((body.tools as any[])[0].function.name, "stock_y_ventas");
});

Deno.test("aChatCompletions: sin temperature, y reasoning_effort sólo si se pide", () => {
  const sin = aChatCompletions(REQ_CON_PARALELAS, "gpt-6-luna");
  assertEquals("temperature" in sin, false);
  assertEquals("reasoning_effort" in sin, false);
  assertEquals(aChatCompletions(REQ_CON_PARALELAS, "gpt-6-luna", "minimal").reasoning_effort, "minimal");
});

Deno.test("aChatCompletions: una respuesta sin llamada se descarta (OpenAI rechazaría todo)", () => {
  const body = aChatCompletions({
    contents: [
      { role: "user", parts: [{ functionResponse: { name: "x", response: {} } }] },
      { role: "user", parts: [{ text: "hola" }] },
    ],
  }, "gpt-6-luna");
  // deno-lint-ignore no-explicit-any
  assertEquals((body.messages as any[]).map((m) => m.role), ["user"]);
});

Deno.test("aChatCompletions: un turno del modelo vacío no se manda (OpenAI rechazaría todo)", () => {
  const body = aChatCompletions({
    contents: [
      { role: "user", parts: [{ text: "hola" }] },
      { role: "model", parts: [] },
      { role: "user", parts: [{ text: "¿y?" }] },
    ],
  }, "gpt-6-luna");
  // deno-lint-ignore no-explicit-any
  assertEquals((body.messages as any[]).map((m) => m.role), ["user", "user"]);
});

Deno.test("aChatCompletions: una llamada sin respuesta se contesta con error antes del próximo mensaje", () => {
  const body = aChatCompletions({
    contents: [
      { role: "user", parts: [{ text: "x" }] },
      {
        role: "model",
        parts: [
          { functionCall: { name: "a", args: {} } },
          { functionCall: { name: "b", args: {} } },
        ],
      },
      // Sólo vino la respuesta de "a"; "b" quedó colgada (memoria cortada).
      { role: "user", parts: [{ functionResponse: { name: "a", response: { result: 1 } } }] },
      { role: "user", parts: [{ text: "seguí" }] },
    ],
  }, "gpt-6-luna");
  // deno-lint-ignore no-explicit-any
  const msgs = body.messages as any[];
  assertEquals(msgs.map((m) => m.role), ["user", "assistant", "tool", "tool", "user"]);
  assertEquals(msgs[2].tool_call_id, "c1_0");
  assertEquals(msgs[3].tool_call_id, "c1_1");
  assertEquals(JSON.parse(msgs[3].content), { error: "sin respuesta" });
});

Deno.test("aChatCompletions: llamadas al final de la memoria también quedan contestadas", () => {
  const body = aChatCompletions({
    contents: [
      { role: "user", parts: [{ text: "x" }] },
      { role: "model", parts: [{ functionCall: { name: "a", args: {} } }] },
    ],
  }, "gpt-6-luna");
  // deno-lint-ignore no-explicit-any
  assertEquals((body.messages as any[]).map((m) => m.role), ["user", "assistant", "tool"]);
});

Deno.test("deChatCompletions: texto, llamadas y uso con caché, en forma de Gemini", () => {
  const r = deChatCompletions({
    choices: [{
      message: {
        role: "assistant",
        content: "Busco.",
        tool_calls: [{ id: "x", type: "function", function: { name: "buscar_cliente", arguments: '{"q":"Daniel"}' } }],
      },
      finish_reason: "tool_calls",
    }],
    usage: { prompt_tokens: 5000, completion_tokens: 80, total_tokens: 5080, prompt_tokens_details: { cached_tokens: 4000 } },
  });
  const c = r.candidates![0];
  assertEquals(c.finishReason, "STOP");
  assertEquals(c.content.parts, [
    { text: "Busco." },
    { functionCall: { name: "buscar_cliente", args: { q: "Daniel" } } },
  ]);
  assertEquals(r.usageMetadata?.cachedContentTokenCount, 4000);
  assertEquals(r.usageMetadata?.candidatesTokenCount, 80);
});

Deno.test("deChatCompletions: corte por largo es MAX_TOKENS y argumentos rotos son MALFORMED", () => {
  assertEquals(
    deChatCompletions({ choices: [{ message: { content: "a medias" }, finish_reason: "length" }] })
      .candidates![0].finishReason,
    "MAX_TOKENS",
  );
  const roto = deChatCompletions({
    choices: [{
      message: { content: null, tool_calls: [{ function: { name: "x", arguments: "{no es json" } }] },
      finish_reason: "tool_calls",
    }],
  });
  assertEquals(roto.candidates![0].finishReason, "MALFORMED_FUNCTION_CALL");
  assertEquals(roto.candidates![0].content.parts.length, 0);
});

Deno.test("callOpenAI: Bearer, base configurable y reintento ante 429", conEnv({
  OPENAI_API_KEY: "sk-test",
  OPENAI_BASE_URL: "https://proxy.example.com/v1/",
}, async () => {
  const f = stubFetch((_u, n) => n === 1 ? json({ error: "rate" }, 429) : json(openaiTexto("ok")));
  try {
    const r = await callOpenAI({ contents: [{ role: "user", parts: [{ text: "hola" }] }] }, "gpt-6-luna");
    assertEquals(r.candidates![0].content.parts, [{ text: "ok" }]);
    assertEquals(f.llamadas.length, 2);
    assertEquals(f.llamadas[0].url, "https://proxy.example.com/v1/chat/completions");
    assertEquals(f.llamadas[0].headers.get("Authorization"), "Bearer sk-test");
  } finally {
    f.restore();
  }
}));

Deno.test("callOpenAI: sin OPENAI_API_KEY falla claro, sin llamar a nadie", conEnv({}, async () => {
  const f = stubFetch(() => json({}));
  try {
    await assertRejects(() => callOpenAI({ contents: [] }, "gpt-6-luna"), Error, "OPENAI_API_KEY");
    assertEquals(f.llamadas.length, 0);
  } finally {
    f.restore();
  }
}));

// ============================================================================
// 3. generar(): elige proveedor, acota el razonamiento y calcula el costo
// ============================================================================

Deno.test("generar: Gemini 2.5 con razonamiento acotado, y el costo cuenta el razonamiento", conEnv({ GEMINI_API_KEY: "g" }, async () => {
  const f = stubFetch(() =>
    json(geminiTexto("hola", { promptTokenCount: 10_000, candidatesTokenCount: 500, thoughtsTokenCount: 500 }))
  );
  try {
    const g = await generar({ contents: [{ role: "user", parts: [{ text: "x" }] }] }, {
      modelo: "gemini-2.5-flash",
      razonamientoAcotado: true,
    });
    assertStringIncludes(f.llamadas[0].url, "gemini-2.5-flash:generateContent");
    // deno-lint-ignore no-explicit-any
    assertEquals((f.llamadas[0].body as any).generationConfig.thinkingConfig, { thinkingBudget: 512 });
    // 10000*0,30 + 1000*2,50 = 5500 / 1e6
    assertEquals(g.costoUsd.toFixed(4), "0.0055");
  } finally {
    f.restore();
  }
}));

Deno.test("generar: un thinkingConfig propio (el del digest) no se pisa", conEnv({ GEMINI_API_KEY: "g" }, async () => {
  const f = stubFetch(() => json(geminiTexto("ok")));
  try {
    await generar({
      contents: [{ role: "user", parts: [{ text: "x" }] }],
      generationConfig: { thinkingConfig: { thinkingBudget: 0 } },
    }, { modelo: "gemini-2.5-flash", razonamientoAcotado: true });
    // deno-lint-ignore no-explicit-any
    assertEquals((f.llamadas[0].body as any).generationConfig.thinkingConfig, { thinkingBudget: 0 });
  } finally {
    f.restore();
  }
}));

Deno.test("generar: gpt-* va a OpenAI y vuelve con forma de Gemini", conEnv({ OPENAI_API_KEY: "sk" }, async () => {
  const f = stubFetch(() => json(openaiTexto("Hola desde OpenAI")));
  try {
    const g = await generar({ contents: [{ role: "user", parts: [{ text: "x" }] }] }, {
      modelo: "gpt-6-luna",
      razonamientoAcotado: true,
    });
    assertStringIncludes(f.llamadas[0].url, "api.openai.com/v1/chat/completions");
    assertEquals(g.response.candidates![0].content.parts, [{ text: "Hola desde OpenAI" }]);
    // 1000*0,10 + 100*0,50 = 150 / 1e6
    assertEquals(g.costoUsd.toFixed(6), "0.000150");
    assertEquals(g.modelo, "gpt-6-luna");
  } finally {
    f.restore();
  }
}));

// ============================================================================
// 4. Techo de gasto
// ============================================================================

Deno.test("decidirModelo: agotado pasa al barato, y si ya es el barato, a sólo botones", conEnv({}, () => {
  assertEquals(decidirModelo({ usd: 1, techo: 10, nivel: "ok" }), {
    modo: "modelo",
    modelo: "gemini-2.5-flash",
    degradado: false,
  });
  assertEquals(decidirModelo({ usd: 8.5, techo: 10, nivel: "aviso" }).modo, "modelo");
  assertEquals(decidirModelo({ usd: 10, techo: 10, nivel: "agotado" }), {
    modo: "modelo",
    modelo: "gemini-2.5-flash-lite",
    degradado: true,
  });
  Deno.env.set("BOT_LLM_MODEL", "gemini-2.5-flash-lite");
  assertEquals(decidirModelo({ usd: 10, techo: 10, nivel: "agotado" }), { modo: "solo_botones" });
  Deno.env.set("BOT_LLM_MODEL", "gpt-6-luna");
  Deno.env.set("BOT_LLM_MODEL_FALLBACK", "ninguno");
  assertEquals(decidirModelo({ usd: 10, techo: 10, nivel: "agotado" }), { modo: "solo_botones" });
}));

function sbPresupuesto(opts: {
  estado?: unknown;
  estadoError?: boolean;
  sumar?: unknown;
  admins?: string[];
  chats?: number[];
} = {}) {
  const rpcs: Array<{ fn: string; params?: Record<string, unknown> }> = [];
  // deno-lint-ignore no-explicit-any
  const builder = (table: string): any => {
    // deno-lint-ignore no-explicit-any
    const b: any = {
      select: () => b,
      eq: () => b,
      in: () => b,
      maybeSingle: () => Promise.resolve({ data: null, error: null }),
      upsert: () => Promise.resolve({ error: null }),
      insert: () => Promise.resolve({ error: null }),
      then: (res: (v: unknown) => unknown) =>
        res({
          data: table === "perfiles"
            ? (opts.admins ?? []).map((id) => ({ id }))
            : table === "bot_usuarios"
            ? (opts.chats ?? []).map((telegram_user_id) => ({ telegram_user_id }))
            : [],
          error: null,
        }),
    };
    return b;
  };
  // deno-lint-ignore no-explicit-any
  const client: any = {
    from: (t: string) => builder(t),
    rpc: (fn: string, params?: Record<string, unknown>) => {
      rpcs.push({ fn, params });
      if (fn === "bot_costo_llm_estado") {
        return Promise.resolve(opts.estadoError ? { data: null, error: { message: "caída" } } : { data: opts.estado ?? null, error: null });
      }
      if (fn === "bot_costo_llm_sumar") return Promise.resolve({ data: opts.sumar ?? { nivel: "ok" }, error: null });
      return Promise.resolve({ data: null, error: null });
    },
  };
  return { client: client as SupabaseClient, rpcs };
}

Deno.test("estadoPresupuesto: si la base no contesta, el bot sigue (fail-open)", async () => {
  const { client } = sbPresupuesto({ estadoError: true });
  assertEquals((await estadoPresupuesto(client)).nivel, "ok");
});

Deno.test("registrarCosto: al cruzar el 80% avisa a cada admin vinculado", conEnv({ TELEGRAM_BOT_TOKEN: "t" }, async () => {
  const { client, rpcs } = sbPresupuesto({
    sumar: { usd: 8.01, techo: 10, nivel: "aviso", avisar: "80" },
    admins: ["a1", "a2"],
    chats: [111, 222],
  });
  const f = stubFetch(() => json({ ok: true, result: { message_id: 1 } }));
  try {
    await registrarCosto(client, 0.0123456789, 2);
    assertEquals(rpcs[0], { fn: "bot_costo_llm_sumar", params: { p_usd: 0.012346, p_llamadas: 2 } });
    const enviados = f.llamadas.filter((l) => l.url.includes("sendMessage"));
    assertEquals(enviados.map((l) => l.body?.chat_id), [111, 222]);
    assertStringIncludes(String(enviados[0].body?.text), "USD 8.01 de USD 10.00");
  } finally {
    f.restore();
  }
}));

Deno.test("registrarCosto: sin cruce no avisa, y sin costo ni llamadas no consulta", async () => {
  const { client, rpcs } = sbPresupuesto({ sumar: { usd: 1, techo: 10, nivel: "ok", avisar: null } });
  const f = stubFetch(() => json({ ok: true }));
  try {
    await registrarCosto(client, 0.001, 1);
    assertEquals(f.llamadas.length, 0);
    await registrarCosto(client, 0, 0);
    assertEquals(rpcs.length, 1);
  } finally {
    f.restore();
  }
});

Deno.test("textoAviso: el de agotado dice qué pasa hasta fin de mes", () => {
  assertStringIncludes(textoAviso("agotado", { usd: 10.02, techo: 10, nivel: "agotado" }), "modelo más barato");
});

// ============================================================================
// 5. El agente: respuestas agrupadas y techo
// ============================================================================

function makeUser(): BotUser {
  return {
    telegram_user_id: 42,
    perfil_id: "11111111-1111-1111-1111-111111111111",
    rol: "admin",
    sucursal_id: 1,
    activo: true,
  };
}

function setupAgente() {
  limpiarEnv();
  Deno.env.set("GEMINI_API_KEY", "g");
  clearSystemPromptCache();
  setSystemPromptForTests("admin", "PROMPT_TEST");
  _clearToolsForTests();
  _resetRegisterFlagForTests();
  const eco: Tool<{ q: string }, { eco: string }> = {
    name: "eco",
    description: "devuelve lo que recibe",
    parameters: { type: "object", properties: { q: { type: "string" } }, required: ["q"] },
    allowedRoles: ["admin"],
    handler: ({ q }) => Promise.resolve({ eco: q }),
  };
  registerTool(eco);
}

function teardownAgente() {
  limpiarEnv();
  clearSystemPromptCache();
  _clearToolsForTests();
  _resetRegisterFlagForTests();
  _setServiceRoleClientForTests(null);
}

Deno.test("runAgent: dos llamadas paralelas → sus respuestas van en UN turno, en orden", async () => {
  setupAgente();
  const { client } = sbPresupuesto();
  _setServiceRoleClientForTests(client as never);
  const f = stubFetch((_u, n) =>
    json(
      n === 1
        ? {
          candidates: [{
            content: {
              role: "model",
              parts: [
                { functionCall: { name: "eco", args: { q: "uno" } } },
                { functionCall: { name: "eco", args: { q: "dos" } } },
              ],
            },
            finishReason: "STOP",
          }],
        }
        : geminiTexto("listo"),
    )
  );
  try {
    const r = await runAgent({ supabase: client, user: makeUser(), telegram_user_id: 42, userMessage: "x", ephemeral: true });
    assertEquals(r.text, "listo");
    // deno-lint-ignore no-explicit-any
    const contents = (f.llamadas[1].body as any).contents as GeminiContent[];
    const ultimo = contents[contents.length - 1];
    assertEquals(ultimo.role, "user");
    assertEquals(ultimo.parts, [
      { functionResponse: { name: "eco", response: { result: { eco: "uno" } } } },
      { functionResponse: { name: "eco", response: { result: { eco: "dos" } } } },
    ]);
    assertEquals(r.toolCalls.map((t) => t.args.q), ["uno", "dos"]);
    // Sin capturarResultados no se guardan los datos.
    assertEquals(r.toolCalls[0].data, undefined);
  } finally {
    f.restore();
    teardownAgente();
  }
});

Deno.test("runAgent: con el mes agotado y ya en el modelo barato, contesta sin llamar a ningún modelo", async () => {
  setupAgente();
  Deno.env.set("BOT_LLM_MODEL", "gemini-2.5-flash-lite");
  const { client, rpcs } = sbPresupuesto({ estado: { usd: 10.5, techo: 10, nivel: "agotado" } });
  _setServiceRoleClientForTests(client as never);
  const f = stubFetch(() => json(geminiTexto("no debería")));
  try {
    const r = await runAgent({ supabase: client, user: makeUser(), telegram_user_id: 42, userMessage: "ventas?" });
    assertEquals(r.text, MENSAJE_SOLO_BOTONES);
    assertEquals(f.llamadas.filter((l) => l.url.includes("generativelanguage")).length, 0);
    assertEquals(rpcs.some((x) => x.fn === "bot_costo_llm_sumar"), false);
  } finally {
    f.restore();
    teardownAgente();
  }
});

Deno.test("runAgent: con el mes agotado pasa al barato y suma lo gastado", async () => {
  setupAgente();
  const { client, rpcs } = sbPresupuesto({ estado: { usd: 10.5, techo: 10, nivel: "agotado" } });
  _setServiceRoleClientForTests(client as never);
  const f = stubFetch(() => json(geminiTexto("hola", { promptTokenCount: 1000, candidatesTokenCount: 100 })));
  try {
    const r = await runAgent({ supabase: client, user: makeUser(), telegram_user_id: 42, userMessage: "hola" });
    assertStringIncludes(f.llamadas[0].url, "gemini-2.5-flash-lite:generateContent");
    assertEquals(r.modelo, "gemini-2.5-flash-lite");
    const suma = rpcs.find((x) => x.fn === "bot_costo_llm_sumar");
    // flash-lite: 1000*0,10 + 100*0,40 = 140 / 1e6
    assertEquals(suma?.params, { p_usd: 0.00014, p_llamadas: 1 });
  } finally {
    f.restore();
    teardownAgente();
  }
});

Deno.test("runAgent: con `modelo` explícito (la evaluación) no mira ni suma el techo", async () => {
  setupAgente();
  const { client, rpcs } = sbPresupuesto({ estado: { usd: 10.5, techo: 10, nivel: "agotado" } });
  _setServiceRoleClientForTests(client as never);
  const f = stubFetch(() => json(geminiTexto("hola")));
  try {
    const r = await runAgent({
      supabase: client,
      user: makeUser(),
      telegram_user_id: -979,
      userMessage: "hola",
      ephemeral: true,
      modelo: "gemini-2.5-flash",
    });
    assertEquals(r.modelo, "gemini-2.5-flash");
    assertEquals(rpcs.filter((x) => x.fn.startsWith("bot_costo_llm")).length, 0);
  } finally {
    f.restore();
    teardownAgente();
  }
});

// ============================================================================
// 6. Memoria compacta y orden del prompt
// ============================================================================

Deno.test("compactarRespuestas: recorta resultados largos y no toca llamadas ni textos cortos", () => {
  const largo = { result: { filas: Array.from({ length: 200 }, (_, i) => ({ i, nombre: `PRODUCTO ${i}` })) } };
  const history: GeminiContent[] = [
    { role: "user", parts: [{ text: "stock" }] },
    { role: "model", parts: [{ functionCall: { name: "stock_y_ventas", args: { texto: "a" } } }] },
    {
      role: "user",
      parts: [
        { functionResponse: { name: "stock_y_ventas", response: largo } },
        { functionResponse: { name: "eco", response: { result: "corto" } } },
      ],
    },
  ];
  const c = compactarRespuestas(history);
  assertEquals(c[0], history[0]);
  assertEquals(c[1], history[1]);
  // deno-lint-ignore no-explicit-any
  const r0 = (c[2].parts[0] as any).functionResponse.response;
  assertEquals(r0.recortado, true);
  assertEquals(r0.inicio.length, MAX_CHARS_RESULTADO_EN_MEMORIA);
  assertEquals(c[2].parts[1], history[2].parts[1]);
});

Deno.test("appendFunctionResponses: sin respuestas no agrega un turno vacío", () => {
  const h: GeminiContent[] = [{ role: "user", parts: [{ text: "x" }] }];
  assertEquals(appendFunctionResponses(h, []), h);
});

Deno.test("getSystemPrompt: lo fijo primero (cacheable) y la fecha al final", async () => {
  clearSystemPromptCache();
  const p = await getSystemPrompt("admin");
  assert(!p.startsWith("CONTEXTO DE FECHA"), "la fecha no puede ir adelante: rompe la caché");
  assert(p.indexOf("CÓMO RESPONDER") < p.indexOf("CONTEXTO DE FECHA (zona"));
  assertStringIncludes(p, "Sin período: últimos 30 días");
  assertStringIncludes(p, "nunca lo estimes ni lo inventes");
});

Deno.test("reasoningEffortDefault: gpt-6-luna va con 'none' (con herramientas lo exige), el resto sin valor", () => {
  assertEquals(reasoningEffortDefault("gpt-6-luna"), "none");
  assertEquals(reasoningEffortDefault("gpt-6-luna-2026-09"), "none");
  assertEquals(reasoningEffortDefault("gpt-5-nano"), undefined);
});

Deno.test("callOpenAI: a gpt-6-luna le manda reasoning_effort 'none' y la variable lo pisa", conEnv({ OPENAI_API_KEY: "sk" }, async () => {
  const f = stubFetch(() => json(openaiTexto("ok")));
  try {
    await callOpenAI({ contents: [{ role: "user", parts: [{ text: "x" }] }] }, "gpt-6-luna");
    assertEquals(f.llamadas[0].body?.reasoning_effort, "none");
    Deno.env.set("BOT_REASONING_EFFORT", "low");
    await callOpenAI({ contents: [{ role: "user", parts: [{ text: "x" }] }] }, "gpt-6-luna");
    assertEquals(f.llamadas[1].body?.reasoning_effort, "low");
  } finally {
    f.restore();
  }
}));

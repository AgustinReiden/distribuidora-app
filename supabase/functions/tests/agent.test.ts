// Tests Deno para el loop del agente Gemini (Phase 3 task 3.2).
// Correr con: deno task test (desde supabase/functions/).
//
// Estrategia de mocking:
//   * `globalThis.fetch` interceptado para Gemini (mismo patrón que
//     gemini.test.ts). Cada test puede programar una secuencia de
//     respuestas — `nextGeminiResponses` se shift-ea por iteración.
//   * Supabase mock minimal: maneja `from('bot_conversaciones').select.eq.maybeSingle()`,
//     `from('bot_conversaciones').upsert(...)`, `from('bot_audit_log').insert(...)`.
//     Tools mockeadas via tool registry directamente.
//   * `_setServiceRoleClientForTests` redirige `logEvent` al mismo mock.
//
// Cubrimos:
//   1. Happy path simple (sin tools): user "hola" → text directo.
//   2. Happy path con 1 tool call: tool buscar_cliente → mock supabase →
//      text con info del cliente.
//   3. Tool call que falla: invokeTool retorna ok:false → siguiente Gemini
//      call recibe {error} y emite mensaje user-friendly.
//   4. Max iterations: Gemini siempre emite functionCall → hitMaxIterations
//      true, fallback message.
//   5. Safety block: candidates vacíos + promptFeedback.blockReason="SAFETY" →
//      fallback, audit con blocked=SAFETY.
//   6. Memory load + save: history previo de 4 turnos cargado, llamada Gemini
//      lo incluye, upsert se llama con history actualizado.
//   7. truncateHistory: 50 turnos con functionResponse mal-emparejado al
//      inicio del tail → cap respetado y sin huérfano.

import {
  assert,
  assertEquals,
  assertStringIncludes,
} from "std/assert/mod.ts";
import type { SupabaseClient } from "@supabase/supabase-js";

import { runAgent } from "../_shared/gemini/agent.ts";
import { truncateHistory } from "../_shared/gemini/memory.ts";
import type { GeminiContent } from "../_shared/gemini/types.ts";
import {
  clearSystemPromptCache,
  setSystemPromptForTests,
} from "../_shared/gemini/prompts/base.ts";
import {
  _clearToolsForTests,
  _resetRegisterFlagForTests,
  registerTool,
} from "../_shared/tools/index.ts";
import type { Tool } from "../_shared/tools/base.ts";
import { _setServiceRoleClientForTests } from "../_shared/supabase.ts";
import type { BotUser } from "../_shared/types.ts";

// ============================================================================
// Test scaffolding
// ============================================================================

interface MockSupabaseSpy {
  upserts: Array<{ table: string; row: Record<string, unknown> }>;
  inserts: Array<{ table: string; row: Record<string, unknown> }>;
  selects: Array<{ table: string }>;
}

interface MockSupabaseOpts {
  /** Si está, `bot_conversaciones.select.eq.maybeSingle()` retorna { data, error:null }. */
  conversacionData?: { mensajes: GeminiContent[] } | null;
  /** Forzar error en saveConversation. */
  upsertError?: { message: string } | null;
}

function createMockSupabase(opts: MockSupabaseOpts = {}): {
  client: SupabaseClient;
  spy: MockSupabaseSpy;
} {
  const spy: MockSupabaseSpy = { upserts: [], inserts: [], selects: [] };

  function makeBuilder(table: string) {
    // deno-lint-ignore no-explicit-any
    const builder: any = {
      select(_cols: string) {
        spy.selects.push({ table });
        return builder;
      },
      eq(_col: string, _val: unknown) {
        return builder;
      },
      maybeSingle() {
        if (table === "bot_conversaciones") {
          return Promise.resolve({
            data: opts.conversacionData ?? null,
            error: null,
          });
        }
        return Promise.resolve({ data: null, error: null });
      },
      upsert(row: Record<string, unknown>) {
        spy.upserts.push({ table, row });
        return Promise.resolve({ error: opts.upsertError ?? null });
      },
      insert(row: Record<string, unknown>) {
        spy.inserts.push({ table, row });
        return Promise.resolve({ error: null });
      },
    };
    return builder;
  }

  // deno-lint-ignore no-explicit-any
  const client: any = {
    from(table: string) {
      return makeBuilder(table);
    },
    rpc(_fn: string, _params: Record<string, unknown>) {
      return Promise.resolve({ data: null, error: null });
    },
  };
  return { client: client as SupabaseClient, spy };
}

interface FetchSpy {
  calls: Array<{ url: string; body: unknown }>;
}

/**
 * Stub de fetch para Gemini. `responses` es una cola: cada llamada toma el
 * siguiente elemento. Si hay menos respuestas que llamadas, lanza para
 * exponer el bug rápido.
 */
function installGeminiFetchStub(
  responses: Array<Record<string, unknown>>,
): { spy: FetchSpy; restore: () => void } {
  const original = globalThis.fetch;
  const spy: FetchSpy = { calls: [] };
  const queue = [...responses];

  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    let bodyParsed: unknown = null;
    try {
      bodyParsed = init?.body ? JSON.parse(init.body as string) : null;
    } catch {
      bodyParsed = null;
    }
    spy.calls.push({ url, body: bodyParsed });
    const next = queue.shift();
    if (!next) {
      throw new Error(
        `installGeminiFetchStub: no quedan respuestas en la queue (call #${spy.calls.length})`,
      );
    }
    return Promise.resolve(
      new Response(JSON.stringify(next), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
  }) as typeof fetch;

  return {
    spy,
    restore: () => {
      globalThis.fetch = original;
    },
  };
}

function makeUser(rol: BotUser["rol"] = "admin"): BotUser {
  return {
    telegram_user_id: 42,
    perfil_id: "11111111-1111-1111-1111-111111111111",
    rol,
    sucursal_id: 1,
    activo: true,
  };
}

/** Setup común: API key seteada, prompt overrideado, registry limpio. */
function setupAgentEnv(): void {
  Deno.env.set("GEMINI_API_KEY", "test-key");
  clearSystemPromptCache();
  setSystemPromptForTests("admin", "TEST_PROMPT_ADMIN");
  setSystemPromptForTests("preventista", "TEST_PROMPT_PREV");
  setSystemPromptForTests("transportista", "TEST_PROMPT_TRANS");
  setSystemPromptForTests("encargado", "TEST_PROMPT_ENC");
  setSystemPromptForTests("deposito", "TEST_PROMPT_DEP");
  _clearToolsForTests();
  _resetRegisterFlagForTests();
}

function teardownAgentEnv(): void {
  Deno.env.delete("GEMINI_API_KEY");
  clearSystemPromptCache();
  _clearToolsForTests();
  _resetRegisterFlagForTests();
  _setServiceRoleClientForTests(null);
}

// ============================================================================
// 1. Happy path simple (sin tools, sin function calls)
// ============================================================================

Deno.test("runAgent happy path simple: 'hola' → respuesta de texto directa", async () => {
  setupAgentEnv();
  const { client, spy } = createMockSupabase({ conversacionData: null });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installGeminiFetchStub([
    {
      candidates: [
        {
          content: {
            role: "model",
            parts: [{ text: "¡Hola! ¿En qué te ayudo?" }],
          },
          finishReason: "STOP",
        },
      ],
      usageMetadata: { totalTokenCount: 25 },
    },
  ]);

  try {
    const result = await runAgent({
      supabase: client,
      user: makeUser("admin"),
      telegram_user_id: 42,
      userMessage: "hola",
    });

    assertEquals(result.text, "¡Hola! ¿En qué te ayudo?");
    assertEquals(result.toolCallsCount, 0);
    assertEquals(result.iterations, 1);
    assertEquals(result.finishReason, "STOP");
    assertEquals(result.totalTokens, 25);
    assertEquals(result.hitMaxIterations, false);

    // Una sola llamada a Gemini.
    assertEquals(fetchStub.spy.calls.length, 1);
    // El system prompt debe haber sido enviado.
    const reqBody = fetchStub.spy.calls[0].body as Record<string, unknown>;
    const sysInst = reqBody.system_instruction as { parts: { text: string }[] };
    assertEquals(sysInst.parts[0].text, "TEST_PROMPT_ADMIN");
    // El user message está en contents.
    const contents = reqBody.contents as GeminiContent[];
    assertEquals(contents.length, 1);
    assertEquals(contents[0].role, "user");

    // Memoria: hubo upsert con el history actualizado.
    const upsert = spy.upserts.find((u) => u.table === "bot_conversaciones");
    assert(upsert, "debió persistir el history");
    const mensajes = upsert!.row.mensajes as GeminiContent[];
    assertEquals(mensajes.length, 2); // user + model
    assertEquals(mensajes[0].role, "user");
    assertEquals(mensajes[1].role, "model");

    // Audit: tipo='respuesta'.
    const auditResp = spy.inserts.find((i) =>
      i.table === "bot_audit_log" && i.row.tipo === "respuesta"
    );
    assert(auditResp, "debió haber audit tipo='respuesta'");
    assertEquals(auditResp!.row.texto_bot, "¡Hola! ¿En qué te ayudo?");
  } finally {
    fetchStub.restore();
    teardownAgentEnv();
  }
});

// ============================================================================
// 2. Happy path con 1 tool call
// ============================================================================

Deno.test("runAgent con 1 tool call: functionCall → invokeTool → text final", async () => {
  setupAgentEnv();
  const { client } = createMockSupabase({ conversacionData: null });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  // Mock tool que devuelve datos canned.
  const fakeTool: Tool<{ q: string }, { clientes: { nombre: string }[] }> = {
    name: "buscar_cliente_fake",
    description: "test tool",
    parameters: {
      type: "object",
      properties: { q: { type: "string" } },
      required: ["q"],
    },
    allowedRoles: ["admin"],
    handler: ({ q }) =>
      Promise.resolve({ clientes: [{ nombre: `Pepe ${q}` }] }),
  };
  registerTool(fakeTool);

  const fetchStub = installGeminiFetchStub([
    // Iter 1: Gemini emite functionCall.
    {
      candidates: [
        {
          content: {
            role: "model",
            parts: [
              {
                functionCall: {
                  name: "buscar_cliente_fake",
                  args: { q: "X" },
                },
              },
            ],
          },
          finishReason: "STOP",
        },
      ],
      usageMetadata: { totalTokenCount: 100 },
    },
    // Iter 2: Gemini emite texto final con la info del tool.
    {
      candidates: [
        {
          content: {
            role: "model",
            parts: [{ text: "Encontré a Pepe X." }],
          },
          finishReason: "STOP",
        },
      ],
      usageMetadata: { totalTokenCount: 50 },
    },
  ]);

  try {
    const result = await runAgent({
      supabase: client,
      user: makeUser("admin"),
      telegram_user_id: 42,
      userMessage: "buscame pepe",
    });

    assertEquals(result.text, "Encontré a Pepe X.");
    assertEquals(result.toolCallsCount, 1);
    assertEquals(result.iterations, 2);
    assertEquals(result.totalTokens, 150);
    assertEquals(result.hitMaxIterations, false);

    // 2 calls a Gemini.
    assertEquals(fetchStub.spy.calls.length, 2);

    // La 2da request a Gemini debe contener el functionResponse del tool.
    const secondReq = fetchStub.spy.calls[1].body as Record<string, unknown>;
    const contents = secondReq.contents as GeminiContent[];
    // Esperamos: [user, model(functionCall), user(functionResponse)].
    assertEquals(contents.length, 3);
    assertEquals(contents[2].role, "user");
    const fnRespPart = contents[2].parts[0] as {
      functionResponse: { name: string; response: Record<string, unknown> };
    };
    assertEquals(fnRespPart.functionResponse.name, "buscar_cliente_fake");
    // result wrapeado en {result: ...}.
    assert(
      "result" in fnRespPart.functionResponse.response,
      "el response debe tener {result: ...} en el éxito",
    );
  } finally {
    fetchStub.restore();
    teardownAgentEnv();
  }
});

// ============================================================================
// 3. Tool call que falla
// ============================================================================

Deno.test("runAgent tool error: invokeTool ok:false → response.error → user-friendly text", async () => {
  setupAgentEnv();
  const { client } = createMockSupabase({ conversacionData: null });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const failingTool: Tool<Record<string, unknown>, never> = {
    name: "tool_que_falla",
    description: "test tool that throws",
    parameters: { type: "object", properties: {} },
    allowedRoles: ["admin"],
    handler: () => Promise.reject(new Error("Cliente no encontrado")),
  };
  registerTool(failingTool);

  const fetchStub = installGeminiFetchStub([
    // Iter 1: emit functionCall.
    {
      candidates: [
        {
          content: {
            role: "model",
            parts: [
              { functionCall: { name: "tool_que_falla", args: {} } },
            ],
          },
          finishReason: "STOP",
        },
      ],
      usageMetadata: { totalTokenCount: 80 },
    },
    // Iter 2: Gemini ve el error y responde texto user-friendly.
    {
      candidates: [
        {
          content: {
            role: "model",
            parts: [{ text: "No encontré ese cliente. Probá con otro nombre." }],
          },
          finishReason: "STOP",
        },
      ],
      usageMetadata: { totalTokenCount: 40 },
    },
  ]);

  try {
    const result = await runAgent({
      supabase: client,
      user: makeUser("admin"),
      telegram_user_id: 42,
      userMessage: "buscame algo",
    });

    assertEquals(result.text, "No encontré ese cliente. Probá con otro nombre.");
    assertEquals(result.toolCallsCount, 1);
    assertEquals(result.iterations, 2);

    // La 2da request debe llevar {error: "..."} (NO {result: ...}).
    const secondReq = fetchStub.spy.calls[1].body as Record<string, unknown>;
    const contents = secondReq.contents as GeminiContent[];
    const fnRespPart = contents[2].parts[0] as {
      functionResponse: { name: string; response: Record<string, unknown> };
    };
    assert(
      "error" in fnRespPart.functionResponse.response,
      "el response debe tener {error: ...} en el fallo",
    );
    assertEquals(
      fnRespPart.functionResponse.response.error,
      "Cliente no encontrado",
    );
  } finally {
    fetchStub.restore();
    teardownAgentEnv();
  }
});

// ============================================================================
// 4. Max iterations
// ============================================================================

Deno.test("runAgent max iterations: tool calls infinitos → hitMaxIterations true", async () => {
  setupAgentEnv();
  const { client, spy } = createMockSupabase({ conversacionData: null });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const loopTool: Tool<Record<string, unknown>, { ok: boolean }> = {
    name: "loop_tool",
    description: "test tool that always succeeds",
    parameters: { type: "object", properties: {} },
    allowedRoles: ["admin"],
    handler: () => Promise.resolve({ ok: true }),
  };
  registerTool(loopTool);

  // Programamos MAX_TOOL_ITERATIONS=8 respuestas (default actual), todas con
  // functionCall. La constante se lee del env var en module init de agent.ts,
  // así que el test usa el default. Si más adelante se quiere parametrizar
  // por test, hay que reestructurar agent.ts para leer per-call.
  const responses = Array.from({ length: 8 }, () => ({
    candidates: [
      {
        content: {
          role: "model",
          parts: [{ functionCall: { name: "loop_tool", args: {} } }],
        },
        finishReason: "STOP",
      },
    ],
    usageMetadata: { totalTokenCount: 10 },
  }));
  const fetchStub = installGeminiFetchStub(responses);

  try {
    const result = await runAgent({
      supabase: client,
      user: makeUser("admin"),
      telegram_user_id: 42,
      userMessage: "loop por favor",
    });

    assertEquals(result.hitMaxIterations, true);
    assertEquals(result.iterations, 8);
    assertEquals(result.toolCallsCount, 8);
    assertEquals(result.totalTokens, 80);
    assertStringIncludes(result.text, "complejo");

    // Audit: tipo='error' con hit_max_iterations=true.
    const auditErr = spy.inserts.find((i) =>
      i.table === "bot_audit_log" && i.row.tipo === "error"
    );
    assert(auditErr, "debió haber audit tipo='error'");
    const meta = auditErr!.row.resultado_meta as Record<string, unknown>;
    assertEquals(meta.hit_max_iterations, true);
  } finally {
    fetchStub.restore();
    teardownAgentEnv();
  }
});

// ============================================================================
// 5. Safety block (sin candidato)
// ============================================================================

Deno.test("runAgent safety block: candidates vacíos + blockReason → fallback con audit", async () => {
  setupAgentEnv();
  const { client, spy } = createMockSupabase({ conversacionData: null });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installGeminiFetchStub([
    {
      candidates: [],
      promptFeedback: { blockReason: "SAFETY" },
      usageMetadata: { totalTokenCount: 5 },
    },
  ]);

  try {
    const result = await runAgent({
      supabase: client,
      user: makeUser("admin"),
      telegram_user_id: 42,
      userMessage: "<contenido bloqueado>",
    });

    assertEquals(result.finishReason, "SAFETY");
    assertEquals(result.iterations, 1);
    assertEquals(result.toolCallsCount, 0);
    assertEquals(result.hitMaxIterations, false);
    assertStringIncludes(result.text, "No pude procesar");

    // Audit: respuesta con blocked=SAFETY.
    const auditResp = spy.inserts.find((i) =>
      i.table === "bot_audit_log" && i.row.tipo === "respuesta"
    );
    assert(auditResp, "debió haber audit tipo='respuesta'");
    const meta = auditResp!.row.resultado_meta as Record<string, unknown>;
    assertEquals(meta.blocked, "SAFETY");
  } finally {
    fetchStub.restore();
    teardownAgentEnv();
  }
});

// ============================================================================
// 6. Memory load + save
// ============================================================================

Deno.test("runAgent memoria: carga history previo y persiste el actualizado", async () => {
  setupAgentEnv();

  // History previo: 4 turnos válidos (user, model, user, model).
  const previo: GeminiContent[] = [
    { role: "user", parts: [{ text: "primera pregunta" }] },
    { role: "model", parts: [{ text: "primera respuesta" }] },
    { role: "user", parts: [{ text: "segunda pregunta" }] },
    { role: "model", parts: [{ text: "segunda respuesta" }] },
  ];

  const { client, spy } = createMockSupabase({
    conversacionData: { mensajes: previo },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installGeminiFetchStub([
    {
      candidates: [
        {
          content: {
            role: "model",
            parts: [{ text: "respuesta nueva" }],
          },
          finishReason: "STOP",
        },
      ],
      usageMetadata: { totalTokenCount: 30 },
    },
  ]);

  try {
    await runAgent({
      supabase: client,
      user: makeUser("admin"),
      telegram_user_id: 42,
      userMessage: "tercera pregunta",
    });

    // 1) La llamada a Gemini debe incluir los 4 turnos previos + el nuevo user.
    assertEquals(fetchStub.spy.calls.length, 1);
    const reqBody = fetchStub.spy.calls[0].body as Record<string, unknown>;
    const contents = reqBody.contents as GeminiContent[];
    assertEquals(contents.length, 5); // 4 previos + nuevo user
    assertEquals(contents[0].role, "user");
    assertEquals(contents[3].role, "model");
    assertEquals(contents[4].role, "user");
    const lastUserPart = contents[4].parts[0] as { text: string };
    assertEquals(lastUserPart.text, "tercera pregunta");

    // 2) saveConversation: upsert con history actualizado (4 + nuevo user + nuevo model = 6).
    const upsert = spy.upserts.find((u) => u.table === "bot_conversaciones");
    assert(upsert, "debió haber upsert a bot_conversaciones");
    const mensajes = upsert!.row.mensajes as GeminiContent[];
    assertEquals(mensajes.length, 6);
    assertEquals(mensajes[5].role, "model");

    // 3) onConflict telegram_user_id (verificable por la presencia de telegram_user_id en row).
    assertEquals(upsert!.row.telegram_user_id, 42);
  } finally {
    fetchStub.restore();
    teardownAgentEnv();
  }
});

// ============================================================================
// 7. truncateHistory edge case: 50 turnos → 12 sin huérfano
// ============================================================================

Deno.test("truncateHistory deja exactamente N turnos sin functionResponse huérfano al inicio", () => {
  // Construimos 50 turnos: alterna user(text) / model(text) — todos
  // emparejados sanos.
  const sano: GeminiContent[] = [];
  for (let i = 0; i < 25; i++) {
    sano.push({ role: "user", parts: [{ text: `q${i}` }] });
    sano.push({ role: "model", parts: [{ text: `a${i}` }] });
  }
  assertEquals(sano.length, 50);

  const tr = truncateHistory(sano, 12);
  assertEquals(tr.length, 12);
  // El primero debe ser un "user" con texto plano.
  assertEquals(tr[0].role, "user");
  assert(
    tr[0].parts.every((p) => "text" in p),
    "el primer turno tras truncar debe ser user con texto plano",
  );
});

Deno.test("truncateHistory salta functionResponse huérfano si quedó al inicio", () => {
  // 50 turnos donde algunos tramos contienen tool calls.
  // Construimos así: 38 turnos planos (user/model alternados) + un patrón
  // tool-heavy al final: ...model(fnCall), user(fnResponse), model(text), user(text), ...
  //
  // Cap 12 → tail = últimos 12 turnos. Si el primer turno del tail es un
  // user(functionResponse), debe ser descartado hasta el primer user(text).
  const h: GeminiContent[] = [];
  // 38 planos.
  for (let i = 0; i < 19; i++) {
    h.push({ role: "user", parts: [{ text: `q${i}` }] });
    h.push({ role: "model", parts: [{ text: `a${i}` }] });
  }
  // Tail con tool-pattern: 12 turnos donde [0]=user(functionResponse) huérfano.
  // Pre-tail (idx 38..49):
  // 38: user(fnResponse) ← este será el [0] del tail con cap 12 → huérfano.
  // 39: model(text)
  // 40: user(text)
  // 41: model(text)
  // ... etc.
  h.push({
    role: "user",
    parts: [{ functionResponse: { name: "x", response: { result: 1 } } }],
  });
  h.push({ role: "model", parts: [{ text: "post tool" }] });
  for (let i = 0; i < 5; i++) {
    h.push({ role: "user", parts: [{ text: `qq${i}` }] });
    h.push({ role: "model", parts: [{ text: `aa${i}` }] });
  }

  assertEquals(h.length, 50);

  const tr = truncateHistory(h, 12);
  // El primer turno debe ser un user(text), no el functionResponse huérfano.
  assertEquals(tr[0].role, "user");
  assert(
    tr[0].parts.every((p) => "text" in p),
    "tras truncar, el primer turno debe ser user con texto plano (no functionResponse huérfano)",
  );
  // Y el tail final debe estar contenido — al menos los últimos turnos siguen ahí.
  assertEquals(tr[tr.length - 1].role, "model");
});

Deno.test("truncateHistory no toca history de longitud <= cap", () => {
  const h: GeminiContent[] = [
    { role: "user", parts: [{ text: "a" }] },
    { role: "model", parts: [{ text: "b" }] },
  ];
  const tr = truncateHistory(h, 12);
  assertEquals(tr, h);
});

// ============================================================================
// interactableContext (Task 4.3): runAgent expone la última tool call
// que devolvió una lista de items con id+nombre, así el handler arma un
// inline keyboard al final.
// ============================================================================

Deno.test("runAgent: buscar_cliente popula interactableContext={kind:'clientes'}", async () => {
  setupAgentEnv();
  const { client } = createMockSupabase({ conversacionData: null });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  // Tool con el name reconocido por extractInteractableContext.
  // Devuelve el shape que la tool real produce.
  const fakeBuscarCliente: Tool<
    { q: string },
    { total: number; clientes: Array<{ id: number; nombre: string }> }
  > = {
    name: "buscar_cliente",
    description: "test tool",
    parameters: {
      type: "object",
      properties: { q: { type: "string" } },
      required: ["q"],
    },
    allowedRoles: ["admin"],
    handler: () =>
      Promise.resolve({
        total: 2,
        clientes: [
          { id: 42, nombre: "Pepito SA" },
          { id: 100, nombre: "Almacén Centro" },
        ],
      }),
  };
  registerTool(fakeBuscarCliente);

  const fetchStub = installGeminiFetchStub([
    {
      candidates: [{
        content: {
          role: "model",
          parts: [{ functionCall: { name: "buscar_cliente", args: { q: "Pe" } } }],
        },
        finishReason: "STOP",
      }],
      usageMetadata: { totalTokenCount: 50 },
    },
    {
      candidates: [{
        content: {
          role: "model",
          parts: [{ text: "Encontré 2 clientes." }],
        },
        finishReason: "STOP",
      }],
      usageMetadata: { totalTokenCount: 30 },
    },
  ]);

  try {
    const result = await runAgent({
      supabase: client,
      user: makeUser("admin"),
      telegram_user_id: 42,
      userMessage: "buscame pe",
    });

    assert(result.interactableContext, "interactableContext debe estar populado");
    assertEquals(result.interactableContext!.kind, "clientes");
    assertEquals(result.interactableContext!.items.length, 2);
    assertEquals(result.interactableContext!.items[0], { id: 42, nombre: "Pepito SA" });
    assertEquals(result.interactableContext!.items[1], { id: 100, nombre: "Almacén Centro" });
  } finally {
    fetchStub.restore();
    teardownAgentEnv();
  }
});

Deno.test("runAgent: tool no reconocida (ej ficha_cliente) NO popula interactableContext", async () => {
  setupAgentEnv();
  const { client } = createMockSupabase({ conversacionData: null });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  // Tool con shape de single-item — extractInteractableContext debe
  // retornar undefined (un keyboard de 1 botón sería ruido).
  const fakeFichaCliente: Tool<
    { cliente_id: number },
    { cliente: { id: number; nombre: string } }
  > = {
    name: "ficha_cliente",
    description: "test tool",
    parameters: {
      type: "object",
      properties: { cliente_id: { type: "integer" } },
      required: ["cliente_id"],
    },
    allowedRoles: ["admin"],
    handler: () => Promise.resolve({ cliente: { id: 42, nombre: "Pepito" } }),
  };
  registerTool(fakeFichaCliente);

  const fetchStub = installGeminiFetchStub([
    {
      candidates: [{
        content: {
          role: "model",
          parts: [{ functionCall: { name: "ficha_cliente", args: { cliente_id: 42 } } }],
        },
        finishReason: "STOP",
      }],
      usageMetadata: { totalTokenCount: 50 },
    },
    {
      candidates: [{
        content: {
          role: "model",
          parts: [{ text: "Pepito tiene saldo X." }],
        },
        finishReason: "STOP",
      }],
      usageMetadata: { totalTokenCount: 30 },
    },
  ]);

  try {
    const result = await runAgent({
      supabase: client,
      user: makeUser("admin"),
      telegram_user_id: 42,
      userMessage: "ficha de pepito",
    });

    assertEquals(
      result.interactableContext,
      undefined,
      "ficha_cliente NO debe popular interactableContext",
    );
  } finally {
    fetchStub.restore();
    teardownAgentEnv();
  }
});

// ============================================================================
// 9. MALFORMED_FUNCTION_CALL → mensaje accionable (no fallback genérico)
// ============================================================================

Deno.test("runAgent MALFORMED_FUNCTION_CALL devuelve un mensaje accionable", async () => {
  setupAgentEnv();
  const { client, spy } = createMockSupabase({ conversacionData: null });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  // Gemini emite parts vacías + finishReason MALFORMED_FUNCTION_CALL
  // (este es el shape real cuando rechaza un function call mal formado).
  const fetchStub = installGeminiFetchStub([
    {
      candidates: [
        {
          content: { role: "model", parts: [] },
          finishReason: "MALFORMED_FUNCTION_CALL",
        },
      ],
      usageMetadata: { totalTokenCount: 3880 },
    },
  ]);

  try {
    const result = await runAgent({
      supabase: client,
      user: makeUser("admin"),
      telegram_user_id: 42,
      userMessage: "Decime cuánto vendimos ayer",
    });

    assertEquals(result.finishReason, "MALFORMED_FUNCTION_CALL");
    assertEquals(result.toolCallsCount, 0);
    assertEquals(result.hitMaxIterations, false);
    assertStringIncludes(result.text, "No logré armar la consulta");
    assertStringIncludes(result.text, "ej:");

    // Audit con malformed=true.
    const auditResp = spy.inserts.find((i) =>
      i.table === "bot_audit_log" && i.row.tipo === "respuesta"
    );
    assert(auditResp, "debió haber audit tipo='respuesta'");
    const meta = auditResp!.row.resultado_meta as Record<string, unknown>;
    assertEquals(meta.malformed, true);
    assertEquals(meta.finishReason, "MALFORMED_FUNCTION_CALL");
  } finally {
    fetchStub.restore();
    teardownAgentEnv();
  }
});

// ============================================================================
// 10. Silent STOP (finishReason=STOP, sin tools, sin texto) → mensaje accionable
// ============================================================================

Deno.test("runAgent silent STOP devuelve mensaje accionable distinto al genérico", async () => {
  setupAgentEnv();
  const { client, spy } = createMockSupabase({ conversacionData: null });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  // Gemini emite parts vacías + finishReason STOP — el modelo "pensó" pero
  // no se anima a tool-callear ni a producir texto. Caso real visto en prod
  // con Gemini 2.5 Flash con thinking on.
  const fetchStub = installGeminiFetchStub([
    {
      candidates: [
        {
          content: { role: "model", parts: [] },
          finishReason: "STOP",
        },
      ],
      usageMetadata: { totalTokenCount: 5223 },
    },
  ]);

  try {
    const result = await runAgent({
      supabase: client,
      user: makeUser("admin"),
      telegram_user_id: 42,
      userMessage: "Decime cuál fue la última venta al kiosco arquitectura UNT",
    });

    assertEquals(result.finishReason, "STOP");
    assertEquals(result.toolCallsCount, 0);
    assertEquals(result.hitMaxIterations, false);
    assertStringIncludes(result.text, "No estoy seguro");
    assertStringIncludes(result.text, "contexto");
    // No debe ser ni el de MALFORMED ni el genérico viejo.
    assert(!result.text.includes("No logré armar"));
    assert(!result.text.includes("Probá reformular"));

    // Audit con silent_stop=true.
    const auditResp = spy.inserts.find((i) =>
      i.table === "bot_audit_log" && i.row.tipo === "respuesta"
    );
    assert(auditResp, "debió haber audit tipo='respuesta'");
    const meta = auditResp!.row.resultado_meta as Record<string, unknown>;
    assertEquals(meta.silent_stop, true);
    assertEquals(meta.finishReason, "STOP");
    // malformed NO debe estar marcado.
    assertEquals(meta.malformed, undefined);
  } finally {
    fetchStub.restore();
    teardownAgentEnv();
  }
});

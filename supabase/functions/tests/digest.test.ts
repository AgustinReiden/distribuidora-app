// Tests Deno para el digest ejecutivo diario (Phase 4 task 4.1).
// Correr con: deno task test (desde supabase/functions/).
//
// Cubrimos:
//   1. runDigestForAdmin happy path: RPC OK + Gemini OK + Telegram OK →
//      status='ok', UPSERT con status='ok', audit log insertado.
//   2. runDigestForAdmin skip si ya se envió: select retorna {status:'ok'} →
//      status='skipped', no llama RPC ni Gemini ni Telegram.
//   3. runDigestForAdmin error en RPC: rpc retorna error → status='error',
//      UPSERT con status='error' y stage='metricas'.
//   4. runDigestForAdmin error en Gemini: fetch a Gemini tira → status='error',
//      stage='gemini'.
//   5. runDigestForAdmin error en Telegram: fetch a Telegram tira → status='error',
//      stage='telegram'.
//   6. runDigestForAdmin texto vacío de Gemini → status='error', stage='gemini'.
//   7. runDigestForAdmin reintenta si la fila previa es status='error' (no skip).

import { assert, assertEquals, assertStringIncludes } from "std/assert/mod.ts";
import type { SupabaseClient } from "@supabase/supabase-js";

import {
  _clearDigestPromptCacheForTests,
  _setDigestPromptForTests,
  runDigestForAdmin,
} from "../telegram-digest/digest.ts";
import { _setServiceRoleClientForTests } from "../_shared/supabase.ts";

// ============================================================================
// Mock helpers
// ============================================================================

interface MockSpy {
  upserts: Array<{ table: string; row: Record<string, unknown>; opts?: unknown }>;
  inserts: Array<{ table: string; row: Record<string, unknown> }>;
  rpcCalls: Array<{ fn: string; params: Record<string, unknown> }>;
  selectQueries: Array<{ table: string; eqs: Array<{ col: string; val: unknown }> }>;
}

interface MockOpts {
  /** Lo que retorna la query de idempotencia: select.eq.eq.maybeSingle(). */
  existenteData?: Record<string, unknown> | null;
  /** Respuesta del rpc bot_metricas_admin_dia. */
  rpcResponse?: { data: unknown; error: { message: string } | null };
  /** Forzar error en upsert. Default: ok. */
  upsertError?: { message: string } | null;
}

function createMockSupabase(opts: MockOpts = {}): {
  client: SupabaseClient;
  spy: MockSpy;
} {
  const spy: MockSpy = {
    upserts: [],
    inserts: [],
    rpcCalls: [],
    selectQueries: [],
  };

  function makeBuilder(table: string) {
    const eqs: Array<{ col: string; val: unknown }> = [];
    // deno-lint-ignore no-explicit-any
    const builder: any = {
      select(_cols: string) {
        spy.selectQueries.push({ table, eqs });
        return builder;
      },
      eq(col: string, val: unknown) {
        eqs.push({ col, val });
        return builder;
      },
      maybeSingle() {
        if (table === "bot_digests_enviados") {
          return Promise.resolve({
            data: opts.existenteData ?? null,
            error: null,
          });
        }
        return Promise.resolve({ data: null, error: null });
      },
      upsert(row: Record<string, unknown>, upsertOpts?: unknown) {
        spy.upserts.push({ table, row, opts: upsertOpts });
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
    rpc(fn: string, params: Record<string, unknown>) {
      spy.rpcCalls.push({ fn, params });
      return Promise.resolve(
        opts.rpcResponse ?? { data: null, error: null },
      );
    },
  };
  return { client: client as SupabaseClient, spy };
}

interface FetchSpy {
  calls: Array<{ url: string; body: unknown }>;
}

/**
 * Stub de fetch que diferencia llamadas a Gemini vs Telegram por host.
 * `gemini` y `telegram` son funciones que retornan Response (o tiran).
 */
function installFetchStub(handlers: {
  gemini?: (body: unknown) => Response | Promise<Response>;
  telegram?: (body: unknown) => Response | Promise<Response>;
}): { spy: FetchSpy; restore: () => void } {
  const original = globalThis.fetch;
  const spy: FetchSpy = { calls: [] };

  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    let body: unknown = null;
    try {
      body = init?.body ? JSON.parse(init.body as string) : null;
    } catch {
      body = null;
    }
    spy.calls.push({ url, body });

    if (url.includes("generativelanguage.googleapis.com")) {
      if (handlers.gemini) return Promise.resolve(handlers.gemini(body));
      throw new Error("unexpected gemini call");
    }
    if (url.includes("api.telegram.org")) {
      if (handlers.telegram) return Promise.resolve(handlers.telegram(body));
      throw new Error("unexpected telegram call");
    }
    throw new Error(`unexpected fetch URL: ${url}`);
  }) as typeof fetch;

  return {
    spy,
    restore: () => {
      globalThis.fetch = original;
    },
  };
}

function makeArgs() {
  return {
    telegram_user_id: 42,
    perfil_id: "11111111-1111-1111-1111-111111111111",
    sucursal_id: 1,
    fecha: "2026-04-26",
  };
}

const FAKE_METRICAS = {
  fecha: "2026-04-26",
  ventas_dia: { pedidos: 12, total: 125500, ticket_promedio: 10458.33 },
  promedio_7d: { pedidos_dia_avg: 10, total_dia_avg: 106000 },
  delta_pct: 18.4,
  top_clientes: [
    { cliente_id: 5, nombre: "Almacén Centro", pedidos: 2, total: 45000 },
  ],
  top_productos: [],
  pendientes_entrega: { count: 3, monto: 12000 },
  pendientes_pago: { count: 2, saldo: 9500 },
  stock_critico: { count: 0, top: [] },
  cuentas_por_cobrar: { clientes_con_saldo: 5, deuda_total: 89300 },
  cxc_vencido: { pedidos_vencidos: 0, monto_vencido: 0 },
  rendiciones_pendientes: { count: 0, dias_mas_vieja: 0 },
  recorridos_hoy: { count: 1, en_curso: 1, total_paradas: 8 },
};

function setupEnv(): void {
  Deno.env.set("GEMINI_API_KEY", "test-key");
  Deno.env.set("TELEGRAM_BOT_TOKEN", "test-token");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-key");
  _clearDigestPromptCacheForTests();
  _setDigestPromptForTests("TEST_DIGEST_PROMPT");
}

function teardownEnv(): void {
  Deno.env.delete("GEMINI_API_KEY");
  Deno.env.delete("TELEGRAM_BOT_TOKEN");
  Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY");
  _clearDigestPromptCacheForTests();
  _setServiceRoleClientForTests(null);
}

function geminiOK(text: string): Response {
  return new Response(
    JSON.stringify({
      candidates: [
        { content: { role: "model", parts: [{ text }] }, finishReason: "STOP" },
      ],
      usageMetadata: { totalTokenCount: 50 },
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

function telegramOK(): Response {
  return new Response(
    JSON.stringify({ ok: true, result: { message_id: 1 } }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

// ============================================================================
// 1. Happy path
// ============================================================================

Deno.test("runDigestForAdmin happy path: RPC + Gemini + Telegram → status=ok", async () => {
  setupEnv();
  const { client, spy } = createMockSupabase({
    existenteData: null,
    rpcResponse: { data: FAKE_METRICAS, error: null },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installFetchStub({
    gemini: () => geminiOK("Ayer +18% vs promedio: $125.500 en 12 pedidos."),
    telegram: () => telegramOK(),
  });

  try {
    const result = await runDigestForAdmin(client, makeArgs());

    assertEquals(result.status, "ok");

    // Check del select de idempotencia.
    const selectQ = spy.selectQueries.find((q) => q.table === "bot_digests_enviados");
    assert(selectQ, "debió hacer el select de idempotencia");
    const eqPerfil = selectQ!.eqs.find((e) => e.col === "admin_perfil_id");
    const eqFecha = selectQ!.eqs.find((e) => e.col === "fecha");
    assert(eqPerfil && eqFecha, "select debió tener eq por admin_perfil_id y fecha");

    // RPC fue llamada con args correctos.
    const rpcCall = spy.rpcCalls.find((c) => c.fn === "bot_metricas_admin_dia");
    assert(rpcCall, "debió llamar al RPC bot_metricas_admin_dia");
    assertEquals(rpcCall!.params.p_fecha, "2026-04-26");
    assertEquals(rpcCall!.params.p_sucursal_id, 1);

    // Gemini fue llamado con el system prompt.
    const geminiCall = fetchStub.spy.calls.find((c) => c.url.includes("generativelanguage"));
    assert(geminiCall, "debió llamar a Gemini");
    const geminiBody = geminiCall!.body as Record<string, unknown>;
    const sys = geminiBody.system_instruction as { parts: { text: string }[] };
    assertEquals(sys.parts[0].text, "TEST_DIGEST_PROMPT");

    // Telegram recibió el mensaje con el header del digest + texto.
    const tgCall = fetchStub.spy.calls.find((c) => c.url.includes("api.telegram.org"));
    assert(tgCall, "debió llamar a Telegram");
    const tgBody = tgCall!.body as { chat_id: number; text: string };
    assertEquals(tgBody.chat_id, 42);
    // Header con emoji 🌅 + fecha legible (dd/mm/yyyy via Intl). El día
    // de la semana depende del locale del runtime — solo aserto que esté
    // el emoji + la fecha en formato legible + el texto del LLM.
    assertStringIncludes(tgBody.text, "🌅 Resumen");
    assertStringIncludes(tgBody.text, "26/04/2026");
    assertStringIncludes(tgBody.text, "Ayer +18%");

    // UPSERT en bot_digests_enviados con status='ok'.
    const upsert = spy.upserts.find((u) => u.table === "bot_digests_enviados");
    assert(upsert, "debió hacer UPSERT en bot_digests_enviados");
    assertEquals(upsert!.row.status, "ok");
    assertEquals(upsert!.row.admin_perfil_id, "11111111-1111-1111-1111-111111111111");
    assertEquals(upsert!.row.fecha, "2026-04-26");
    assertEquals(upsert!.row.error_meta, null);

    // Audit log insertado con tipo='respuesta'.
    const auditResp = spy.inserts.find(
      (i) => i.table === "bot_audit_log" && i.row.tipo === "respuesta",
    );
    assert(auditResp, "debió insertar audit log");
    const meta = auditResp!.row.resultado_meta as Record<string, unknown>;
    assertEquals(meta.digest, true);
    assertEquals(meta.fecha, "2026-04-26");
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

// ============================================================================
// 2. Skip si ya se envió
// ============================================================================

Deno.test("runDigestForAdmin skip si bot_digests_enviados ya tiene status=ok", async () => {
  setupEnv();
  const { client, spy } = createMockSupabase({
    existenteData: { status: "ok" },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installFetchStub({}); // no se debe llamar nada

  try {
    const result = await runDigestForAdmin(client, makeArgs());

    assertEquals(result.status, "skipped");
    assertEquals(result.reason, "already_sent");

    // No debe haber RPC ni fetch ni upsert.
    assertEquals(spy.rpcCalls.length, 0, "no debía llamar al RPC");
    assertEquals(fetchStub.spy.calls.length, 0, "no debía hacer fetch");
    assertEquals(spy.upserts.length, 0, "no debía hacer upsert");
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

// ============================================================================
// 3. Error en RPC
// ============================================================================

Deno.test("runDigestForAdmin error en RPC → status=error y stage=metricas", async () => {
  setupEnv();
  const { client, spy } = createMockSupabase({
    existenteData: null,
    rpcResponse: { data: null, error: { message: "permission denied" } },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installFetchStub({}); // ni Gemini ni Telegram

  try {
    const result = await runDigestForAdmin(client, makeArgs());

    assertEquals(result.status, "error");
    assertStringIncludes(result.reason ?? "", "permission denied");

    // No fetch.
    assertEquals(fetchStub.spy.calls.length, 0);

    // UPSERT con error_meta.stage=metricas.
    const upsert = spy.upserts.find((u) => u.table === "bot_digests_enviados");
    assert(upsert, "debió registrar el error");
    assertEquals(upsert!.row.status, "error");
    const errMeta = upsert!.row.error_meta as Record<string, unknown>;
    assertEquals(errMeta.stage, "metricas");
    assertStringIncludes(String(errMeta.error), "permission denied");
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

// ============================================================================
// 4. Error en Gemini
// ============================================================================

Deno.test("runDigestForAdmin error en Gemini → status=error y stage=gemini", async () => {
  setupEnv();
  const { client, spy } = createMockSupabase({
    existenteData: null,
    rpcResponse: { data: FAKE_METRICAS, error: null },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installFetchStub({
    gemini: () =>
      new Response("server error", {
        status: 500,
        headers: { "Content-Type": "text/plain" },
      }),
    telegram: () => telegramOK(),
  });

  try {
    const result = await runDigestForAdmin(client, makeArgs());

    assertEquals(result.status, "error");
    assert(
      (result.reason ?? "").includes("Gemini") ||
        (result.reason ?? "").toLowerCase().includes("500"),
      `reason debe mencionar Gemini/500: ${result.reason}`,
    );

    // No debe haber llegado a Telegram.
    const tgCall = fetchStub.spy.calls.find((c) => c.url.includes("api.telegram.org"));
    assertEquals(tgCall, undefined, "no debía llamar a Telegram");

    // UPSERT con stage=gemini.
    const upsert = spy.upserts.find((u) => u.table === "bot_digests_enviados");
    assert(upsert, "debió registrar el error");
    assertEquals(upsert!.row.status, "error");
    const errMeta = upsert!.row.error_meta as Record<string, unknown>;
    assertEquals(errMeta.stage, "gemini");
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

// ============================================================================
// 5. Error en Telegram
// ============================================================================

Deno.test("runDigestForAdmin error en Telegram → status=error y stage=telegram", async () => {
  setupEnv();
  const { client, spy } = createMockSupabase({
    existenteData: null,
    rpcResponse: { data: FAKE_METRICAS, error: null },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installFetchStub({
    gemini: () => geminiOK("digest text"),
    telegram: () =>
      new Response(
        JSON.stringify({
          ok: false,
          error_code: 403,
          description: "Forbidden: bot was blocked by the user",
        }),
        { status: 403, headers: { "Content-Type": "application/json" } },
      ),
  });

  try {
    const result = await runDigestForAdmin(client, makeArgs());

    assertEquals(result.status, "error");
    assertStringIncludes(result.reason ?? "", "blocked");

    // UPSERT con stage=telegram.
    const upsert = spy.upserts.find((u) => u.table === "bot_digests_enviados");
    assert(upsert, "debió registrar el error");
    assertEquals(upsert!.row.status, "error");
    const errMeta = upsert!.row.error_meta as Record<string, unknown>;
    assertEquals(errMeta.stage, "telegram");
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

// ============================================================================
// 6. Texto vacío de Gemini
// ============================================================================

Deno.test("runDigestForAdmin texto vacío de Gemini → status=error y stage=gemini", async () => {
  setupEnv();
  const { client, spy } = createMockSupabase({
    existenteData: null,
    rpcResponse: { data: FAKE_METRICAS, error: null },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installFetchStub({
    gemini: () => geminiOK("   "), // whitespace only → tras trim queda vacío
    telegram: () => telegramOK(),
  });

  try {
    const result = await runDigestForAdmin(client, makeArgs());

    assertEquals(result.status, "error");
    assertStringIncludes(result.reason ?? "", "empty");

    // No llegó a Telegram.
    const tgCall = fetchStub.spy.calls.find((c) => c.url.includes("api.telegram.org"));
    assertEquals(tgCall, undefined);

    const upsert = spy.upserts.find((u) => u.table === "bot_digests_enviados");
    assert(upsert);
    const errMeta = upsert!.row.error_meta as Record<string, unknown>;
    assertEquals(errMeta.stage, "gemini");
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

// ============================================================================
// 7. Idempotencia con status='error' previo: NO skipea, reintenta
// ============================================================================

Deno.test("runDigestForAdmin reintenta si la fila previa es status=error", async () => {
  setupEnv();
  const { client, spy } = createMockSupabase({
    // Fila existente pero con status=error → debe reintentar (no skip).
    existenteData: { status: "error" },
    rpcResponse: { data: FAKE_METRICAS, error: null },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installFetchStub({
    gemini: () => geminiOK("ahora sí salió"),
    telegram: () => telegramOK(),
  });

  try {
    const result = await runDigestForAdmin(client, makeArgs());

    assertEquals(result.status, "ok");

    // Hubo RPC + fetch + upsert.
    assert(spy.rpcCalls.length > 0, "debió reintentar el RPC");
    const upsert = spy.upserts.find((u) => u.table === "bot_digests_enviados");
    assert(upsert);
    assertEquals(upsert!.row.status, "ok");
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

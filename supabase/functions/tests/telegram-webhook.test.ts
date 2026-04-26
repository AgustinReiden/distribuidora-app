// Tests Deno para la Edge Function telegram-webhook.
// Correr con: deno task test (desde supabase/functions/).
//
// Cubrimos:
//   1. parseUpdate rechaza payloads malformados
//   2. escapeMarkdownV2 escapa todos los caracteres especiales
//   3. sendMessage POSTea correctamente (mock de fetch)
//   4. handleVincular se integra con el RPC (mock del cliente Supabase)

import { assert, assertEquals, assertStringIncludes } from "std/assert/mod.ts";
import {
  escapeMarkdownV2,
  parseUpdate,
  sendMessage,
} from "../_shared/telegram.ts";
import { _setServiceRoleClientForTests } from "../_shared/supabase.ts";

// ============================================================================
// 1. parseUpdate
// ============================================================================

Deno.test("parseUpdate rechaza payloads malformados", () => {
  assertEquals(parseUpdate(null), null);
  assertEquals(parseUpdate(undefined), null);
  assertEquals(parseUpdate("string"), null);
  assertEquals(parseUpdate(42), null);
  assertEquals(parseUpdate({}), null);
  assertEquals(parseUpdate({ update_id: "no-number" }), null);
  assertEquals(parseUpdate({ message: { text: "hola" } }), null);
});

Deno.test("parseUpdate acepta un Update mínimo válido", () => {
  const got = parseUpdate({
    update_id: 1,
    message: {
      message_id: 10,
      date: 1700000000,
      chat: { id: 99, type: "private" },
      from: { id: 99, is_bot: false, first_name: "Tito" },
      text: "/start",
    },
  });
  assert(got !== null);
  assertEquals(got!.update_id, 1);
  assertEquals(got!.message?.text, "/start");
  assertEquals(got!.message?.from?.first_name, "Tito");
  assertEquals(got!.message?.chat.type, "private");
});

Deno.test("parseUpdate ignora chat.type desconocido", () => {
  const got = parseUpdate({
    update_id: 1,
    message: {
      message_id: 10,
      date: 1700000000,
      chat: { id: 99, type: "telephonic" }, // no es válido
      from: { id: 99, is_bot: false, first_name: "Tito" },
      text: "/start",
    },
  });
  // El update_id sigue siendo válido pero el message no se incluye.
  assert(got !== null);
  assertEquals(got!.message, undefined);
});

// ============================================================================
// 2. escapeMarkdownV2
// ============================================================================

Deno.test("escapeMarkdownV2 escapa todos los chars especiales", () => {
  // Lista oficial: _ * [ ] ( ) ~ ` > # + - = | { } . !  y backslash
  const input = "_*[](){}.!#+-=|>~`\\";
  const expected = "\\_\\*\\[\\]\\(\\)\\{\\}\\.\\!\\#\\+\\-\\=\\|\\>\\~\\`\\\\";
  assertEquals(escapeMarkdownV2(input), expected);
});

Deno.test("escapeMarkdownV2 deja texto normal intacto", () => {
  assertEquals(escapeMarkdownV2("hola mundo"), "hola mundo");
  assertEquals(escapeMarkdownV2("Tito Pérez"), "Tito Pérez");
});

Deno.test("escapeMarkdownV2 escapa nombres con punto", () => {
  // Caso típico: apellido + ".com" o iniciales con punto.
  assertEquals(escapeMarkdownV2("Juan A. Pérez"), "Juan A\\. Pérez");
});

// ============================================================================
// 3. sendMessage (mock de fetch)
// ============================================================================

Deno.test("sendMessage POSTea a la URL correcta con el body correcto", async () => {
  const original = globalThis.fetch;
  Deno.env.set("TELEGRAM_BOT_TOKEN", "test-token-123");

  let capturedUrl: string | URL | Request | null = null;
  let capturedInit: RequestInit | undefined;
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    capturedUrl = input;
    capturedInit = init;
    return Promise.resolve(
      new Response(JSON.stringify({ ok: true, result: { message_id: 1 } }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
  }) as typeof fetch;

  try {
    const result = await sendMessage(123, "hola", { parse_mode: "MarkdownV2" });
    assertEquals(result.ok, true);

    assertEquals(
      String(capturedUrl),
      "https://api.telegram.org/bottest-token-123/sendMessage",
    );
    assertEquals(capturedInit?.method, "POST");
    const body = JSON.parse(capturedInit?.body as string);
    assertEquals(body.chat_id, 123);
    assertEquals(body.text, "hola");
    assertEquals(body.parse_mode, "MarkdownV2");
  } finally {
    globalThis.fetch = original;
    Deno.env.delete("TELEGRAM_BOT_TOKEN");
  }
});

Deno.test("sendMessage lanza si la API responde con ok:false", async () => {
  const original = globalThis.fetch;
  Deno.env.set("TELEGRAM_BOT_TOKEN", "test-token-123");

  globalThis.fetch = (() =>
    Promise.resolve(
      new Response(
        JSON.stringify({ ok: false, error_code: 400, description: "Bad chat_id" }),
        { status: 400, headers: { "Content-Type": "application/json" } },
      ),
    )) as typeof fetch;

  try {
    let threw = false;
    try {
      await sendMessage(0, "hola");
    } catch (err) {
      threw = true;
      assertStringIncludes(
        err instanceof Error ? err.message : String(err),
        "Bad chat_id",
      );
    }
    assert(threw, "sendMessage debió lanzar ante ok:false");
  } finally {
    globalThis.fetch = original;
    Deno.env.delete("TELEGRAM_BOT_TOKEN");
  }
});

// ============================================================================
// 4. handleVincular integrado con mock del cliente Supabase
// ============================================================================
//
// Estrategia: importamos handlers.ts AFTER setear el mock del cliente.
// Para evitar contaminación entre tests, reseteamos el singleton y el fetch
// global en finally{}.

interface MockSupabase {
  rpc: (
    fn: string,
    params: Record<string, unknown>,
  ) => Promise<{ data: unknown; error: { message: string } | null }>;
  from: (table: string) => MockTable;
  __rpcCalls: Array<{ fn: string; params: Record<string, unknown> }>;
  __inserts: Array<{ table: string; row: Record<string, unknown> }>;
}

interface MockTable {
  insert: (
    row: Record<string, unknown>,
  ) => Promise<{ error: { message: string } | null }>;
  select: (cols: string) => MockQuery;
}

interface MockQuery {
  eq: (col: string, val: unknown) => MockQuery;
  maybeSingle: () => Promise<
    { data: Record<string, unknown> | null; error: { message: string } | null }
  >;
}

function createMockSupabase(opts: {
  rpcResponse?: { data: unknown; error: { message: string } | null };
  resolveUserData?: Record<string, unknown> | null;
}): MockSupabase {
  const calls: MockSupabase = {
    __rpcCalls: [],
    __inserts: [],
    rpc(fn, params) {
      calls.__rpcCalls.push({ fn, params });
      return Promise.resolve(opts.rpcResponse ?? { data: null, error: null });
    },
    from(table) {
      return {
        insert(row) {
          calls.__inserts.push({ table, row });
          return Promise.resolve({ error: null });
        },
        select(_cols: string) {
          const query: MockQuery = {
            eq() {
              return query;
            },
            maybeSingle() {
              return Promise.resolve({
                data: opts.resolveUserData ?? null,
                error: null,
              });
            },
          };
          return query;
        },
      };
    },
  };
  return calls;
}

function mockTelegramFetch(): { restore: () => void; sent: Array<unknown> } {
  const original = globalThis.fetch;
  const sent: Array<unknown> = [];
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    sent.push({ url: String(input), body: init?.body });
    return Promise.resolve(
      new Response(JSON.stringify({ ok: true, result: { message_id: 1 } }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
  }) as typeof fetch;
  return {
    restore: () => {
      globalThis.fetch = original;
    },
    sent,
  };
}

Deno.test("handleUpdate /vincular OK llama al RPC y manda mensaje de éxito", async () => {
  const { handleUpdate } = await import("../telegram-webhook/handlers.ts");

  Deno.env.set("TELEGRAM_BOT_TOKEN", "test-token");
  const mockSupabase = createMockSupabase({
    rpcResponse: {
      data: {
        success: true,
        perfil_id: "11111111-1111-1111-1111-111111111111",
        rol: "preventista",
        sucursal_id: 7,
        nombre: "Tito",
      },
      error: null,
    },
    resolveUserData: null,
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(mockSupabase as any);

  const fetchMock = mockTelegramFetch();

  try {
    await handleUpdate({
      update_id: 1,
      message: {
        message_id: 1,
        date: 1700000000,
        chat: { id: 555, type: "private" },
        from: { id: 999, is_bot: false, first_name: "Tito", username: "tito" },
        text: "/vincular ABC123",
      },
    });

    // Se llamó al RPC con los args correctos.
    const rpcCall = mockSupabase.__rpcCalls.find((c) =>
      c.fn === "canjear_codigo_vinculacion_bot"
    );
    assert(rpcCall, "no se llamó al RPC canjear_codigo_vinculacion_bot");
    assertEquals(rpcCall!.params.p_codigo, "ABC123");
    assertEquals(rpcCall!.params.p_telegram_user_id, 999);
    assertEquals(rpcCall!.params.p_telegram_username, "tito");

    // Se mandó al menos un mensaje a Telegram con el éxito.
    const exitoMsg = fetchMock.sent.find((s) => {
      const sBody = (s as { body?: string }).body ?? "";
      return sBody.includes("Vinculado correctamente");
    });
    assert(exitoMsg, "no se envió el mensaje de éxito a Telegram");

    // Se logueó audit del comando con success=true.
    const auditOk = mockSupabase.__inserts.find((i) =>
      i.table === "bot_audit_log" && i.row.tool_name === "vincular" &&
      (i.row.resultado_meta as { success?: boolean })?.success === true
    );
    assert(auditOk, "no se logueó audit del vincular OK");
  } finally {
    fetchMock.restore();
    _setServiceRoleClientForTests(null);
    Deno.env.delete("TELEGRAM_BOT_TOKEN");
  }
});

Deno.test("handleUpdate /vincular código expirado manda mensaje de error", async () => {
  const { handleUpdate } = await import("../telegram-webhook/handlers.ts");

  Deno.env.set("TELEGRAM_BOT_TOKEN", "test-token");
  const mockSupabase = createMockSupabase({
    rpcResponse: {
      data: { success: false, error: "expirado" },
      error: null,
    },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(mockSupabase as any);

  const fetchMock = mockTelegramFetch();

  try {
    await handleUpdate({
      update_id: 2,
      message: {
        message_id: 2,
        date: 1700000000,
        chat: { id: 555, type: "private" },
        from: { id: 999, is_bot: false, first_name: "Tito" },
        text: "/vincular ABC123",
      },
    });

    const errorMsg = fetchMock.sent.find((s) => {
      const sBody = (s as { body?: string }).body ?? "";
      return sBody.includes("expir") || sBody.includes("expiró");
    });
    assert(errorMsg, "no se envió mensaje de error de expirado");

    // Audit con success=false.
    const auditFail = mockSupabase.__inserts.find((i) =>
      i.table === "bot_audit_log" && i.row.tool_name === "vincular" &&
      (i.row.resultado_meta as { success?: boolean })?.success === false
    );
    assert(auditFail, "no se logueó audit del vincular fallido");
  } finally {
    fetchMock.restore();
    _setServiceRoleClientForTests(null);
    Deno.env.delete("TELEGRAM_BOT_TOKEN");
  }
});

Deno.test("handleUpdate /vincular código con formato inválido no llama al RPC", async () => {
  const { handleUpdate } = await import("../telegram-webhook/handlers.ts");

  Deno.env.set("TELEGRAM_BOT_TOKEN", "test-token");
  const mockSupabase = createMockSupabase({});
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(mockSupabase as any);

  const fetchMock = mockTelegramFetch();

  try {
    await handleUpdate({
      update_id: 3,
      message: {
        message_id: 3,
        date: 1700000000,
        chat: { id: 555, type: "private" },
        from: { id: 999, is_bot: false, first_name: "Tito" },
        text: "/vincular abc", // 3 chars, no válido
      },
    });

    // No debió llamar al RPC.
    const rpcCalls = mockSupabase.__rpcCalls.filter((c) =>
      c.fn === "canjear_codigo_vinculacion_bot"
    );
    assertEquals(rpcCalls.length, 0);

    const errorMsg = fetchMock.sent.find((s) => {
      const sBody = (s as { body?: string }).body ?? "";
      return sBody.includes("inv");
    });
    assert(errorMsg, "se debió mandar mensaje de código inválido");
  } finally {
    fetchMock.restore();
    _setServiceRoleClientForTests(null);
    Deno.env.delete("TELEGRAM_BOT_TOKEN");
  }
});

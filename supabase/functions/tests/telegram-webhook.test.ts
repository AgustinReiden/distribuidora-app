// Tests Deno para la Edge Function telegram-webhook.
// Correr con: deno task test (desde supabase/functions/).
//
// Cubrimos:
//   1. parseUpdate rechaza payloads malformados
//   2. escapeMarkdownV2 escapa todos los caracteres especiales
//   3. sendMessage POSTea correctamente (mock de fetch)
//   4. handleVincular se integra con el RPC (mock del cliente Supabase)
//   5. parseCommand: extracción de nombre + args (con / sin @bot)
//   6. /cliente, /saldo: flow integrado (router → tool → formatter → sendMessage)
//   7. Scope checks: /misclientes con admin, /recorrido con preventista
//   8. Comando desconocido → mensaje "no reconocido"

import { assert, assertEquals, assertStringIncludes } from "std/assert/mod.ts";
import {
  escapeMarkdownV2,
  parseUpdate,
  sendMessage,
  sendMessageMarkdownSafe,
  timingSafeEqual,
} from "../_shared/telegram.ts";
import { _setServiceRoleClientForTests } from "../_shared/supabase.ts";
import { _resetRegisterFlagForTests, _clearToolsForTests } from "../_shared/tools/index.ts";
import { parseCommand } from "../telegram-webhook/commands/parser.ts";
import { clearCommandsForTests } from "../telegram-webhook/commands/router.ts";

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
// timingSafeEqual
// ============================================================================

Deno.test("timingSafeEqual matchea strings iguales", () => {
  assertEquals(timingSafeEqual("", ""), true);
  assertEquals(timingSafeEqual("a", "a"), true);
  assertEquals(timingSafeEqual("supersecret-123", "supersecret-123"), true);
});

Deno.test("timingSafeEqual rechaza longitudes distintas", () => {
  assertEquals(timingSafeEqual("a", "ab"), false);
  assertEquals(timingSafeEqual("abc", ""), false);
  assertEquals(timingSafeEqual("", "abc"), false);
});

Deno.test("timingSafeEqual rechaza diff en primer char", () => {
  assertEquals(timingSafeEqual("xbc", "abc"), false);
});

Deno.test("timingSafeEqual rechaza diff en último char", () => {
  assertEquals(timingSafeEqual("abc", "abx"), false);
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

Deno.test("sendMessageMarkdownSafe cae a plain text si MarkdownV2 falla", async () => {
  const original = globalThis.fetch;
  Deno.env.set("TELEGRAM_BOT_TOKEN", "test-token-123");

  // Capturamos cada call. Primero retornamos 400 (formato roto), luego 200.
  const calls: Array<{ url: string; init: RequestInit | undefined }> = [];
  let callIdx = 0;
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), init });
    callIdx++;
    if (callIdx === 1) {
      return Promise.resolve(
        new Response(
          JSON.stringify({
            ok: false,
            error_code: 400,
            description: "Bad Request: can't parse entities",
          }),
          { status: 400, headers: { "Content-Type": "application/json" } },
        ),
      );
    }
    return Promise.resolve(
      new Response(JSON.stringify({ ok: true, result: { message_id: 1 } }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
  }) as typeof fetch;

  try {
    // Texto que simula MarkdownV2 con escapes (`\.`) y bold (`*x*`).
    const md = "*Pepito*\nfecha: 20/04/26 \\| saldo";
    await sendMessageMarkdownSafe(123, md);

    assertEquals(calls.length, 2, "debió hacer 2 fetches (md fail + plain retry)");

    // Primer call: con parse_mode MarkdownV2 y el texto crudo.
    const body1 = JSON.parse(calls[0].init?.body as string);
    assertEquals(body1.parse_mode, "MarkdownV2");
    assertEquals(body1.text, md);

    // Segundo call: SIN parse_mode, texto sin `*` y con `\|` despojado a `|`.
    const body2 = JSON.parse(calls[1].init?.body as string);
    assertEquals(
      body2.parse_mode,
      undefined,
      "el retry no debería tener parse_mode",
    );
    assertStringIncludes(body2.text, "Pepito");
    // Ya no debería haber `*` en el plain text.
    assertEquals(body2.text.includes("*"), false, "* no debería sobrevivir");
    // El `\|` debió convertirse a `|` (unescape).
    assertStringIncludes(body2.text, "| saldo");
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

Deno.test("handleUpdate audita el mensaje con perfil_id/rol cuando el user está vinculado", async () => {
  const { handleUpdate } = await import("../telegram-webhook/handlers.ts");

  Deno.env.set("TELEGRAM_BOT_TOKEN", "test-token");
  const mockSupabase = createMockSupabase({
    resolveUserData: {
      telegram_user_id: 999,
      perfil_id: "22222222-2222-2222-2222-222222222222",
      rol: "preventista",
      sucursal_id: 5,
      activo: true,
    },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(mockSupabase as any);

  const fetchMock = mockTelegramFetch();

  try {
    await handleUpdate({
      update_id: 10,
      message: {
        message_id: 10,
        date: 1700000000,
        chat: { id: 555, type: "private" },
        from: { id: 999, is_bot: false, first_name: "Tito" },
        text: "/ayuda",
      },
    });

    // Audit del mensaje DEBE incluir perfil_id y rol del usuario resuelto.
    const auditMensaje = mockSupabase.__inserts.find((i) =>
      i.table === "bot_audit_log" && i.row.tipo === "mensaje"
    );
    assert(auditMensaje, "no se logueó audit del mensaje");
    assertEquals(
      auditMensaje!.row.perfil_id,
      "22222222-2222-2222-2222-222222222222",
    );
    assertEquals(auditMensaje!.row.rol, "preventista");
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

// ============================================================================
// 5. parseCommand
// ============================================================================

Deno.test("parseCommand extrae /<name> + rawArgs", () => {
  assertEquals(parseCommand("/cliente Pepe"), {
    command: "/cliente",
    rawArgs: "Pepe",
  });
  assertEquals(parseCommand("/start"), { command: "/start", rawArgs: "" });
  assertEquals(parseCommand("/saldo  42"), {
    command: "/saldo",
    rawArgs: "42",
  });
});

Deno.test("parseCommand strip @bot_name sufix", () => {
  assertEquals(parseCommand("/cliente@mi_bot Pepe"), {
    command: "/cliente",
    rawArgs: "Pepe",
  });
  assertEquals(parseCommand("/start@mi_bot"), {
    command: "/start",
    rawArgs: "",
  });
});

Deno.test("parseCommand normaliza a lowercase", () => {
  assertEquals(parseCommand("/CLIENTE Pepe"), {
    command: "/cliente",
    rawArgs: "Pepe",
  });
  assertEquals(parseCommand("/Ayuda"), {
    command: "/ayuda",
    rawArgs: "",
  });
});

Deno.test("parseCommand retorna null si no es comando", () => {
  assertEquals(parseCommand("hola"), null);
  assertEquals(parseCommand(""), null);
  assertEquals(parseCommand("   "), null);
  assertEquals(parseCommand("/-invalido"), null);
});

// ============================================================================
// 6/7/8. Tests de comandos del router (mock más completo + import dinámico)
// ============================================================================
//
// Estos tests usan un mock de Supabase más completo que el de la sección 4
// (los handlers de tools encadenan select+eq+or+order+limit, no solo
// eq+maybeSingle). Cada test resetea el registry y el singleton del cliente
// y vuelve a importar handlers.ts para que `bootCommands()` re-registre.

interface RouterMockSpy {
  rpcCalls: Array<{ fn: string; params: Record<string, unknown> }>;
  inserts: Array<{ table: string; row: Record<string, unknown> }>;
  selectQueries: Array<{ table: string; cols: string; filters: unknown[] }>;
}

interface RouterMockOpts {
  /** Respuesta para `.rpc(...)`. Puede variar por nombre de RPC. */
  rpcByFn?: Record<string, { data: unknown; error: { message: string } | null }>;
  /** Respuesta para `.from(table).select(...).<chain>` resuelto como await. */
  selectResponseByTable?: Record<string, {
    data: unknown[] | null;
    error: { message: string } | null;
    count?: number | null;
  }>;
  /** Respuesta para `.from(table).select(...).<chain>.maybeSingle()`. */
  maybeSingleByTable?: Record<string, {
    data: Record<string, unknown> | null;
    error: { message: string } | null;
  }>;
}

// deno-lint-ignore no-explicit-any
function createRouterMockSupabase(opts: RouterMockOpts = {}): { client: any; spy: RouterMockSpy } {
  const spy: RouterMockSpy = { rpcCalls: [], inserts: [], selectQueries: [] };

  function makeBuilder(table: string) {
    const filters: unknown[] = [];
    let isSelect = false;
    let cols = "";

    // deno-lint-ignore no-explicit-any
    const builder: any = {
      insert(row: Record<string, unknown>) {
        spy.inserts.push({ table, row });
        return Promise.resolve({ error: null });
      },
      select(c: string, _selOpts?: Record<string, unknown>) {
        isSelect = true;
        cols = c;
        spy.selectQueries.push({ table, cols, filters });
        return builder;
      },
      eq(col: string, val: unknown) {
        filters.push({ type: "eq", col, val });
        return builder;
      },
      or(expr: string) {
        filters.push({ type: "or", expr });
        return builder;
      },
      order(col: string, _opts?: Record<string, unknown>) {
        filters.push({ type: "order", col });
        return builder;
      },
      limit(n: number) {
        filters.push({ type: "limit", n });
        return builder;
      },
      maybeSingle() {
        const r = opts.maybeSingleByTable?.[table] ??
          { data: null, error: null };
        return Promise.resolve(r);
      },
      // Thenable: cuando se hace `await query` sin terminator explícito,
      // resolvemos con selectResponseByTable[table].
      // deno-lint-ignore no-explicit-any
      then(onFulfilled?: (v: any) => any, onRejected?: (e: any) => any) {
        if (!isSelect) {
          return Promise.resolve({ data: [], error: null }).then(
            onFulfilled,
            onRejected,
          );
        }
        const r = opts.selectResponseByTable?.[table] ??
          { data: [], error: null, count: 0 };
        return Promise.resolve(r).then(onFulfilled, onRejected);
      },
    };
    return builder;
  }

  const client = {
    from(table: string) {
      return makeBuilder(table);
    },
    rpc(fn: string, params: Record<string, unknown>) {
      spy.rpcCalls.push({ fn, params });
      const r = opts.rpcByFn?.[fn] ?? { data: null, error: null };
      return Promise.resolve(r);
    },
  };
  return { client, spy };
}

async function freshHandleUpdate() {
  // Limpia el registry de tools, el de comandos y el flag _booted del módulo
  // handlers.ts — el primer call a handleUpdate va a re-bootear todo. Esto
  // asegura que cada test arranca con el registry limpio (importante porque
  // registerCommand throws on duplicate).
  _clearToolsForTests();
  _resetRegisterFlagForTests();
  clearCommandsForTests();
  const mod = await import("../telegram-webhook/handlers.ts");
  if (typeof mod._resetBootForTests === "function") {
    mod._resetBootForTests();
  }
  return mod.handleUpdate as (u: import("../_shared/types.ts").TelegramUpdate) => Promise<void>;
}

Deno.test("/cliente Pe flow: invoca buscar_cliente y manda mensaje MarkdownV2", async () => {
  const handleUpdate = await freshHandleUpdate();

  Deno.env.set("TELEGRAM_BOT_TOKEN", "test-token");
  const { client, spy } = createRouterMockSupabase({
    selectResponseByTable: {
      clientes: {
        data: [
          {
            id: 42,
            codigo: 100,
            nombre_fantasia: "Pepito SA",
            razon_social: null,
            saldo_cuenta: "1500",
            direccion: "Calle 1",
            zona: "Centro",
            sucursal_id: 1,
          },
        ],
        error: null,
        count: 1,
      },
    },
    maybeSingleByTable: {
      bot_usuarios: {
        data: {
          telegram_user_id: 999,
          perfil_id: "33333333-3333-3333-3333-333333333333",
          rol: "preventista",
          sucursal_id: 1,
          activo: true,
        },
        error: null,
      },
    },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchMock = mockTelegramFetch();

  try {
    await handleUpdate({
      update_id: 100,
      message: {
        message_id: 100,
        date: 1700000000,
        chat: { id: 555, type: "private" },
        from: { id: 999, is_bot: false, first_name: "Tito" },
        text: "/cliente Pe",
      },
    });

    // Se hizo una query a la tabla clientes (la del tool buscar_cliente).
    const clientesQuery = spy.selectQueries.find((q) => q.table === "clientes");
    assert(clientesQuery, "no se hizo query a la tabla clientes");

    // Se mandó al menos un mensaje a Telegram (con MarkdownV2 + el nombre).
    const msg = fetchMock.sent.find((s) => {
      const sBody = (s as { body?: string }).body ?? "";
      return sBody.includes("Pepito SA") && sBody.includes("MarkdownV2");
    });
    assert(msg, "no se mandó el mensaje formateado de buscar_cliente");

    // Se logueó el comando (tipo=comando, tool_name=cliente).
    const auditCmd = spy.inserts.find((i) =>
      i.table === "bot_audit_log" && i.row.tool_name === "cliente" &&
      i.row.tipo === "comando"
    );
    assert(auditCmd, "no se logueó audit del comando /cliente");
  } finally {
    fetchMock.restore();
    _setServiceRoleClientForTests(null);
    Deno.env.delete("TELEGRAM_BOT_TOKEN");
  }
});

Deno.test("/saldo 42 flow: invoca ficha_cliente con cliente_id=42", async () => {
  const handleUpdate = await freshHandleUpdate();

  Deno.env.set("TELEGRAM_BOT_TOKEN", "test-token");
  const { client, spy } = createRouterMockSupabase({
    rpcByFn: {
      obtener_resumen_cuenta_cliente_bot: {
        data: {
          saldo_actual: 1500,
          limite_credito: 5000,
          credito_disponible: 3500,
          total_pedidos: 10,
          total_compras: 50000,
          total_pagos: 48500,
          pedidos_pendientes_pago: 2,
          ultimo_pedido: "2026-04-20",
          ultimo_pago: "2026-04-15",
        },
        error: null,
      },
    },
    maybeSingleByTable: {
      bot_usuarios: {
        data: {
          telegram_user_id: 999,
          perfil_id: "33333333-3333-3333-3333-333333333333",
          rol: "preventista",
          sucursal_id: 1,
          activo: true,
        },
        error: null,
      },
      clientes: {
        data: {
          id: 42,
          codigo: 100,
          nombre_fantasia: "Pepito SA",
          razon_social: null,
          direccion: "Calle 1",
          telefono: "+541112345678",
          zona: "Centro",
          sucursal_id: 1,
        },
        error: null,
      },
    },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchMock = mockTelegramFetch();

  try {
    await handleUpdate({
      update_id: 101,
      message: {
        message_id: 101,
        date: 1700000000,
        chat: { id: 555, type: "private" },
        from: { id: 999, is_bot: false, first_name: "Tito" },
        text: "/saldo 42",
      },
    });

    // Verificar que el RPC se llamó con el cliente_id correcto.
    const rpcCall = spy.rpcCalls.find((c) =>
      c.fn === "obtener_resumen_cuenta_cliente_bot"
    );
    assert(rpcCall, "no se llamó al RPC obtener_resumen_cuenta_cliente_bot");
    assertEquals(rpcCall!.params.p_cliente_id, 42);

    // Mensaje de ficha enviado en MarkdownV2 con el nombre del cliente.
    const msg = fetchMock.sent.find((s) => {
      const sBody = (s as { body?: string }).body ?? "";
      return sBody.includes("Pepito SA") && sBody.includes("MarkdownV2") &&
        sBody.includes("Saldo actual");
    });
    assert(msg, "no se mandó la ficha formateada");

    // Audit del comando /saldo.
    const auditCmd = spy.inserts.find((i) =>
      i.table === "bot_audit_log" && i.row.tool_name === "saldo" &&
      i.row.tipo === "comando"
    );
    assert(auditCmd, "no se logueó audit del comando /saldo");
  } finally {
    fetchMock.restore();
    _setServiceRoleClientForTests(null);
    Deno.env.delete("TELEGRAM_BOT_TOKEN");
  }
});

Deno.test("/misclientes con rol admin: bloqueado por scope", async () => {
  const handleUpdate = await freshHandleUpdate();

  Deno.env.set("TELEGRAM_BOT_TOKEN", "test-token");
  const { client, spy } = createRouterMockSupabase({
    maybeSingleByTable: {
      bot_usuarios: {
        data: {
          telegram_user_id: 999,
          perfil_id: "33333333-3333-3333-3333-333333333333",
          rol: "admin",
          sucursal_id: null,
          activo: true,
        },
        error: null,
      },
    },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchMock = mockTelegramFetch();

  try {
    await handleUpdate({
      update_id: 102,
      message: {
        message_id: 102,
        date: 1700000000,
        chat: { id: 555, type: "private" },
        from: { id: 999, is_bot: false, first_name: "Admin" },
        text: "/misclientes",
      },
    });

    // El RPC bot_mis_clientes NO debe haberse llamado.
    const rpcCall = spy.rpcCalls.find((c) => c.fn === "bot_mis_clientes");
    assertEquals(rpcCall, undefined, "no debió invocarse el tool bot_mis_clientes");

    // Mensaje de scope-block.
    const msg = fetchMock.sent.find((s) => {
      const sBody = (s as { body?: string }).body ?? "";
      return sBody.includes("preventista") && sBody.includes("solo para");
    });
    assert(msg, "no se mandó el mensaje de scope bloqueado");

    // Audit con blocked=rol_no_permitido.
    const auditBlock = spy.inserts.find((i) =>
      i.table === "bot_audit_log" && i.row.tool_name === "misclientes" &&
      (i.row.resultado_meta as { blocked?: string })?.blocked ===
        "rol_no_permitido"
    );
    assert(auditBlock, "no se logueó audit del scope-block");
  } finally {
    fetchMock.restore();
    _setServiceRoleClientForTests(null);
    Deno.env.delete("TELEGRAM_BOT_TOKEN");
  }
});

Deno.test("/recorrido con rol preventista: bloqueado por scope", async () => {
  const handleUpdate = await freshHandleUpdate();

  Deno.env.set("TELEGRAM_BOT_TOKEN", "test-token");
  const { client, spy } = createRouterMockSupabase({
    maybeSingleByTable: {
      bot_usuarios: {
        data: {
          telegram_user_id: 999,
          perfil_id: "33333333-3333-3333-3333-333333333333",
          rol: "preventista",
          sucursal_id: 1,
          activo: true,
        },
        error: null,
      },
    },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchMock = mockTelegramFetch();

  try {
    await handleUpdate({
      update_id: 103,
      message: {
        message_id: 103,
        date: 1700000000,
        chat: { id: 555, type: "private" },
        from: { id: 999, is_bot: false, first_name: "Pre" },
        text: "/recorrido",
      },
    });

    // bot_mi_recorrido NO debe haberse llamado.
    const rpcCall = spy.rpcCalls.find((c) => c.fn === "bot_mi_recorrido");
    assertEquals(rpcCall, undefined);

    const msg = fetchMock.sent.find((s) => {
      const sBody = (s as { body?: string }).body ?? "";
      return sBody.includes("transportista") && sBody.includes("solo para");
    });
    assert(msg, "no se mandó el mensaje de scope bloqueado");
  } finally {
    fetchMock.restore();
    _setServiceRoleClientForTests(null);
    Deno.env.delete("TELEGRAM_BOT_TOKEN");
  }
});

Deno.test("/comando_desconocido manda 'no reconocido'", async () => {
  const handleUpdate = await freshHandleUpdate();

  Deno.env.set("TELEGRAM_BOT_TOKEN", "test-token");
  const { client } = createRouterMockSupabase({
    maybeSingleByTable: {
      bot_usuarios: {
        data: {
          telegram_user_id: 999,
          perfil_id: "33333333-3333-3333-3333-333333333333",
          rol: "preventista",
          sucursal_id: 1,
          activo: true,
        },
        error: null,
      },
    },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchMock = mockTelegramFetch();

  try {
    await handleUpdate({
      update_id: 104,
      message: {
        message_id: 104,
        date: 1700000000,
        chat: { id: 555, type: "private" },
        from: { id: 999, is_bot: false, first_name: "Tito" },
        text: "/comando_inexistente foo",
      },
    });

    const msg = fetchMock.sent.find((s) => {
      const sBody = (s as { body?: string }).body ?? "";
      return sBody.includes("no reconocido");
    });
    assert(msg, "no se mandó el mensaje 'no reconocido'");
  } finally {
    fetchMock.restore();
    _setServiceRoleClientForTests(null);
    Deno.env.delete("TELEGRAM_BOT_TOKEN");
  }
});

// Tests Deno para el digest ejecutivo diario (Phase 4 task 4.1).
// Correr con: deno task test (desde supabase/functions/).
//
// El cuerpo del resumen del admin se arma con una plantilla (admin.ts, #1041):
// ya no hay modelo de por medio, y estos tests lo vigilan (ninguna llamada a
// Gemini ni a OpenAI).
//
// Cubrimos:
//   1. runDigestForAdmin happy path: RPC OK + Telegram OK → status='ok', el
//      texto sale de la plantilla, UPSERT con status='ok', audit log insertado.
//   2. skip si ya se envió: no llama RPC ni Telegram.
//   3. error en RPC → status='error', stage='metricas'.
//   4. error en Telegram → status='error', stage='telegram'.
//   5. reintenta si la fila previa es status='error' (no skip).
//   6. secciones apagadas: no aparecen en el mensaje ni se consultan sus RPCs.
//   7. sección de vencimientos críticos (#565).

import { assert, assertEquals, assertStringIncludes } from "std/assert/mod.ts";
import type { SupabaseClient } from "@supabase/supabase-js";

import { runDigestForAdmin } from "../telegram-digest/digest.ts";
import { formatCurrency } from "../_shared/format.ts";
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
  /** Respuesta del rpc bot_reporte_vencimientos (#565, sección de admin). Default: sin filas. */
  vencimientosRpcResponse?: { data: unknown; error: { message: string } | null };
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
      // bot_reporte_vencimientos (#565, sección de lotes críticos del digest
      // de admin) es una RPC distinta de bot_metricas_admin_dia — sin filas
      // por default, así el happy path no manda una sección de vencimientos
      // que estos tests no cubren.
      if (fn === "bot_reporte_vencimientos") {
        return Promise.resolve(opts.vencimientosRpcResponse ?? { data: [], error: null });
      }
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
 * Stub de fetch que sólo acepta Telegram. El resumen del admin ya no usa
 * ningún modelo: cualquier llamada a Gemini u OpenAI es un error del test
 * (el stub tira, y además queda registrada en `spy.calls` para asertarlo).
 */
function installFetchStub(handlers: {
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

    if (url.includes("generativelanguage.googleapis.com") || url.includes("api.openai.com")) {
      throw new Error(`el resumen del admin no debe llamar a un modelo: ${url}`);
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

/** Llamadas a un modelo (no debería haber ninguna). */
function llamadasAModelo(spy: FetchSpy) {
  return spy.calls.filter((c) =>
    c.url.includes("generativelanguage.googleapis.com") || c.url.includes("api.openai.com")
  );
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
  cxc_vencido: { clientes_vencidos: 0, monto_vencido: 0 },
  rendiciones_pendientes: { count: 0, dias_mas_vieja: 0 },
  recorridos_hoy: { count: 1, en_curso: 1, total_paradas: 8 },
};

function setupEnv(): void {
  Deno.env.set("TELEGRAM_BOT_TOKEN", "test-token");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-key");
}

function teardownEnv(): void {
  Deno.env.delete("TELEGRAM_BOT_TOKEN");
  Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY");
  _setServiceRoleClientForTests(null);
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

Deno.test("runDigestForAdmin happy path: RPC + plantilla + Telegram → status=ok, sin modelo", async () => {
  setupEnv();
  const { client, spy } = createMockSupabase({
    existenteData: null,
    rpcResponse: { data: FAKE_METRICAS, error: null },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installFetchStub({
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

    // El texto sale de la plantilla: ninguna llamada a un modelo.
    assertEquals(llamadasAModelo(fetchStub.spy).length, 0, "no debía llamar a un modelo");

    // Telegram recibió el mensaje con el header del digest + texto.
    const tgCall = fetchStub.spy.calls.find((c) => c.url.includes("api.telegram.org"));
    assert(tgCall, "debió llamar a Telegram");
    const tgBody = tgCall!.body as { chat_id: number; text: string };
    assertEquals(tgBody.chat_id, 42);
    // Header con emoji 🌅 + fecha legible (dd/mm/yyyy via Intl). El día
    // de la semana depende del locale del runtime — solo aserto que esté
    // el emoji + la fecha en formato legible.
    assertStringIncludes(tgBody.text, "🌅 Resumen");
    assertStringIncludes(tgBody.text, "26/04/2026");
    // Y las líneas de la plantilla, derivadas de FAKE_METRICAS.
    assertStringIncludes(tgBody.text, "📊 Pedidos de ayer");
    assertStringIncludes(tgBody.text, `Tomados: ${formatCurrency(125500)} en 12 pedidos`);
    assertStringIncludes(tgBody.text, `promedio 7 días: ${formatCurrency(106000)}, +18%`);
    assertStringIncludes(tgBody.text, "Almacén Centro");
    assertStringIncludes(tgBody.text, `Por cobrar: ${formatCurrency(89300)} de 5 clientes`);

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

  const fetchStub = installFetchStub({}); // ni modelo ni Telegram

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
// 6c. Secciones configurables por admin (#691)
// ============================================================================

Deno.test("runDigestForAdmin: las secciones apagadas no aparecen en el mensaje", async () => {
  setupEnv();
  const { client } = createMockSupabase({
    existenteData: null,
    rpcResponse: { data: FAKE_METRICAS, error: null },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installFetchStub({
    telegram: () => telegramOK(),
  });

  try {
    const result = await runDigestForAdmin(client, {
      ...makeArgs(),
      secciones: ["ventas"],
    });
    assertEquals(result.status, "ok");
    assertEquals(llamadasAModelo(fetchStub.spy).length, 0);

    const tgCall = fetchStub.spy.calls.find((c) => c.url.includes("api.telegram.org"));
    assert(tgCall, "debio enviar el mensaje");
    const texto = String((tgCall!.body as { text?: string }).text);
    // La seccion pedida sale...
    assertStringIncludes(texto, "📊 Pedidos de ayer");
    assertStringIncludes(texto, `Tomados: ${formatCurrency(125500)}`);
    // ...y las apagadas no se nombran, aunque el RPC las trajera con datos.
    assert(!texto.includes("Cuentas por cobrar"), "deuda no debia aparecer");
    assert(!texto.includes("Por cobrar"), "deuda no debia aparecer");
    assert(!texto.includes("Recorridos"), "recorridos no debia aparecer");
    assert(!texto.includes("Almacén Centro"), "top clientes no debia aparecer");
    assert(!texto.includes("Sin entregar"), "pendientes no debia aparecer");
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

Deno.test("runDigestForAdmin: con la seccion 'recorridos' muestra los recorridos de hoy", async () => {
  setupEnv();
  const { client } = createMockSupabase({
    existenteData: null,
    rpcResponse: { data: FAKE_METRICAS, error: null },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installFetchStub({ telegram: () => telegramOK() });

  try {
    const result = await runDigestForAdmin(client, {
      ...makeArgs(),
      secciones: ["ventas", "recorridos"],
    });
    assertEquals(result.status, "ok");
    const tgCall = fetchStub.spy.calls.find((c) => c.url.includes("api.telegram.org"));
    assert(tgCall, "debio enviar el mensaje");
    assertStringIncludes(
      String((tgCall!.body as { text?: string }).text),
      "Recorridos de hoy: 1 (1 en curso), 8 paradas",
    );
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

Deno.test("runDigestForAdmin: sin la seccion 'vencimientos' no se consultan los lotes", async () => {
  setupEnv();
  const { client, spy } = createMockSupabase({
    existenteData: null,
    rpcResponse: { data: FAKE_METRICAS, error: null },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installFetchStub({
    telegram: () => telegramOK(),
  });

  try {
    const result = await runDigestForAdmin(client, {
      ...makeArgs(),
      secciones: ["ventas"],
    });
    assertEquals(result.status, "ok");

    const llamoVencimientos = spy.rpcCalls.some(
      (c) => c.fn === "bot_reporte_vencimientos",
    );
    assert(!llamoVencimientos, "no debia consultar los lotes por vencer");
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

Deno.test("runDigestForAdmin: con 'vencimientos' como unica seccion no consulta bot_metricas_admin_dia", async () => {
  setupEnv();
  const { client, spy } = createMockSupabase({
    existenteData: null,
    rpcResponse: { data: FAKE_METRICAS, error: null },
    vencimientosRpcResponse: {
      data: [
        {
          producto_id: 1,
          producto_nombre: "Coca 2.25L",
          lote_id: 9,
          cantidad_restante: 24,
          fecha_vencimiento: "2026-09-20",
          dias_restantes: 4,
        },
      ],
      error: null,
    },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installFetchStub({
    telegram: () => telegramOK(),
  });

  try {
    const result = await runDigestForAdmin(client, {
      ...makeArgs(),
      secciones: ["vencimientos"],
    });
    assertEquals(result.status, "ok");

    // Sin secciones de metricas no hay nada que pedirle a la RPC de metricas,
    // y nunca hubo un modelo de por medio.
    assertEquals(spy.rpcCalls.some((c) => c.fn === "bot_metricas_admin_dia"), false);
    assertEquals(llamadasAModelo(fetchStub.spy).length, 0);

    const tgCall = fetchStub.spy.calls.find((c) => c.url.includes("api.telegram.org"));
    assert(tgCall, "debio enviar el mensaje igual");
    assertStringIncludes(String((tgCall!.body as { text?: string }).text), "Coca 2.25L");
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

Deno.test("runDigestForAdmin: solo 'vencimientos' y sin lotes → skipped, no manda header solo", async () => {
  setupEnv();
  const { client } = createMockSupabase({
    existenteData: null,
    rpcResponse: { data: FAKE_METRICAS, error: null },
    vencimientosRpcResponse: { data: [], error: null },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installFetchStub({});

  try {
    const result = await runDigestForAdmin(client, {
      ...makeArgs(),
      secciones: ["vencimientos"],
    });

    assertEquals(result.status, "skipped");
    assertEquals(result.reason, "sin_contenido");
    assertEquals(fetchStub.spy.calls.length, 0);
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

// ============================================================================
// 8. Sección de vencimientos críticos (#565)
// ============================================================================

Deno.test("runDigestForAdmin: con lotes críticos → agrega la sección al mismo mensaje", async () => {
  setupEnv();
  const { client } = createMockSupabase({
    existenteData: null,
    rpcResponse: { data: FAKE_METRICAS, error: null },
    vencimientosRpcResponse: {
      data: [
        {
          producto_nombre: "Leche 1L",
          producto_codigo: "LEC-1L",
          cantidad_restante: 12,
          fecha_vencimiento: "2026-04-28",
          dias_restantes: 2,
        },
      ],
      error: null,
    },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installFetchStub({
    telegram: () => telegramOK(),
  });

  try {
    const result = await runDigestForAdmin(client, makeArgs());
    assertEquals(result.status, "ok");

    const tgCall = fetchStub.spy.calls.find((c) => c.url.includes("api.telegram.org"));
    assert(tgCall, "debió llamar a Telegram");
    const tgBody = tgCall!.body as { text: string };
    // El texto de la plantilla sigue intacto, y la sección de vencimientos va después,
    // en el mismo mensaje (no un segundo sendMessage).
    assertStringIncludes(tgBody.text, "📊 Pedidos de ayer");
    assertStringIncludes(tgBody.text, "Lotes en vencimiento crítico");
    assertStringIncludes(tgBody.text, "Leche 1L");
    assertEquals(
      fetchStub.spy.calls.filter((c) => c.url.includes("api.telegram.org")).length,
      1,
      "un solo sendMessage, no dos",
    );
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

Deno.test("runDigestForAdmin: sin lotes críticos → no agrega sección", async () => {
  setupEnv();
  const { client } = createMockSupabase({
    existenteData: null,
    rpcResponse: { data: FAKE_METRICAS, error: null },
    vencimientosRpcResponse: { data: [], error: null },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installFetchStub({
    telegram: () => telegramOK(),
  });

  try {
    await runDigestForAdmin(client, makeArgs());
    const tgCall = fetchStub.spy.calls.find((c) => c.url.includes("api.telegram.org"));
    const tgBody = tgCall!.body as { text: string };
    assertEquals(tgBody.text.includes("vencimiento crítico"), false);
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

Deno.test("runDigestForAdmin: falla la lectura de vencimientos → digest igual sale ok (best-effort)", async () => {
  setupEnv();
  const { client } = createMockSupabase({
    existenteData: null,
    rpcResponse: { data: FAKE_METRICAS, error: null },
    vencimientosRpcResponse: { data: null, error: { message: "rpc caída" } },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installFetchStub({
    telegram: () => telegramOK(),
  });

  try {
    const result = await runDigestForAdmin(client, makeArgs());
    assertEquals(result.status, "ok");
    const tgCall = fetchStub.spy.calls.find((c) => c.url.includes("api.telegram.org"));
    assert(tgCall, "el digest debió mandarse igual");
    const tgBody = tgCall!.body as { text: string };
    assertStringIncludes(tgBody.text, "📊 Pedidos de ayer");
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

Deno.test("runDigestForAdmin: admin sin sucursal (null) → no consulta vencimientos", async () => {
  setupEnv();
  const { client, spy } = createMockSupabase({
    existenteData: null,
    rpcResponse: { data: FAKE_METRICAS, error: null },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const fetchStub = installFetchStub({
    telegram: () => telegramOK(),
  });

  try {
    await runDigestForAdmin(client, { ...makeArgs(), sucursal_id: null });
    const vencimientosCall = spy.rpcCalls.find((c) => c.fn === "bot_reporte_vencimientos");
    assertEquals(
      vencimientosCall,
      undefined,
      "sin sucursal no hay a quién consultarle vencimientos",
    );
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

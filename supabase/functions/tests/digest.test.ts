// Tests Deno para el digest ejecutivo diario (Phase 4 task 4.1).
// Correr con: deno task test (desde supabase/functions/).
//
// El cuerpo del resumen del admin se arma con una plantilla (admin.ts, #1041):
// ya no hay modelo de por medio, y estos tests lo vigilan (ninguna llamada a
// Gemini ni a OpenAI).
//
// Cubrimos:
//   1. runDigestForAdmin happy path: RPC OK + Telegram OK → status='ok', el
//      texto sale de la plantilla, cierre de la marca con status='ok'
//      (bot_digest_registrar), audit log insertado.
//   2. skip si ya se envió (bot_digest_reservar → false): no llama métricas ni Telegram.
//   3. error en RPC → status='error', stage='metricas'.
//   4. error en Telegram → status='error', stage='telegram'.
//   5. reintenta si la marca previa es status='error' (no skip).
//   6. secciones apagadas: no aparecen en el mensaje ni se consultan sus RPCs.
//   7. sección de vencimientos críticos (#565).

import { assert, assertEquals, assertStringIncludes } from "std/assert/mod.ts";
import type { SupabaseClient } from "@supabase/supabase-js";

import { encabezadoDigest, runDigestForAdmin } from "../telegram-digest/digest.ts";
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
  /**
   * La marca previa del día (#1309). `bot_digest_reservar` contesta false si
   * está en ok/enviando/skipped (ya salió o la tiene otra corrida) y true si no
   * hay marca o está en 'error' (se retoma).
   */
  existenteData?: Record<string, unknown> | null;
  /** Fuerza la respuesta de `bot_digest_reservar` (gana sobre `existenteData`). */
  reservaData?: boolean;
  /** Error de `bot_digest_reservar` (la base no contesta). */
  reservaError?: { message: string } | null;
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
      if (fn === "bot_digest_reservar") {
        if (opts.reservaError) return Promise.resolve({ data: null, error: opts.reservaError });
        const previo = (opts.existenteData as { status?: string } | null | undefined)?.status;
        const yaTomada = previo === "ok" || previo === "enviando" || previo === "skipped";
        return Promise.resolve({ data: opts.reservaData ?? !yaTomada, error: null });
      }
      if (fn === "bot_digest_registrar") {
        return Promise.resolve({ data: null, error: null });
      }
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

/** Las llamadas a `bot_digest_registrar` (el cierre de la marca, #1309). */
function registros(spy: MockSpy) {
  return spy.rpcCalls.filter((c) => c.fn === "bot_digest_registrar");
}

/** Las llamadas a `bot_digest_reservar` (la marca previa al envío, #1309). */
function reservas(spy: MockSpy) {
  return spy.rpcCalls.filter((c) => c.fn === "bot_digest_reservar");
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

    // La marca se toma antes de mandar (bot_digest_reservar), por
    // (perfil, sucursal, fecha).
    const reserva = spy.rpcCalls.find((c) => c.fn === "bot_digest_reservar");
    assert(reserva, "debió reservar la marca de idempotencia");
    assertEquals(reserva!.params.p_perfil_id, "11111111-1111-1111-1111-111111111111");
    assertEquals(reserva!.params.p_sucursal_id, 1);
    assertEquals(reserva!.params.p_fecha, "2026-04-26");
    assertEquals(reserva!.params.p_telegram_user_id, 42);
    assertEquals(
      spy.selectQueries.filter((q) => q.table === "bot_digests_enviados").length,
      0,
      "ya no lee bot_digests_enviados a mano",
    );

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

    // Cierre de la marca (bot_digest_registrar) con status='ok'.
    const registro = spy.rpcCalls.find((c) => c.fn === "bot_digest_registrar");
    assert(registro, "debió cerrar la marca con bot_digest_registrar");
    assertEquals(registro!.params.p_status, "ok");
    assertEquals(registro!.params.p_perfil_id, "11111111-1111-1111-1111-111111111111");
    assertEquals(registro!.params.p_sucursal_id, 1);
    assertEquals(registro!.params.p_fecha, "2026-04-26");
    assertEquals(registro!.params.p_error_meta, null);
    assertEquals(
      spy.upserts.filter((u) => u.table === "bot_digests_enviados").length,
      0,
      "ya no escribe bot_digests_enviados a mano",
    );

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

Deno.test("runDigestForAdmin skip si la marca del día ya está tomada (status=ok)", async () => {
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

    // Sólo la reserva (que contestó false): ni métricas, ni vencimientos, ni
    // Telegram, ni cierre de la marca.
    assertEquals(reservas(spy).length, 1, "debía intentar la reserva");
    assertEquals(
      spy.rpcCalls.some((c) => c.fn === "bot_metricas_admin_dia" || c.fn === "bot_reporte_vencimientos"),
      false,
      "no debía llamar al RPC de métricas ni al de vencimientos",
    );
    assertEquals(registros(spy).length, 0, "no debía cerrar una marca que no es suya");
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

    // bot_digest_registrar con error_meta.stage=metricas.
    const registro = registros(spy)[0];
    assert(registro, "debió registrar el error");
    assertEquals(registro.params.p_status, "error");
    assertEquals(registro.params.p_perfil_id, "11111111-1111-1111-1111-111111111111");
    assertEquals(registro.params.p_sucursal_id, 1);
    assertEquals(registro.params.p_fecha, "2026-04-26");
    const errMeta = registro.params.p_error_meta as Record<string, unknown>;
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

  // Un error transitorio de Telegram: queda 'error' y se retoma en la corrida
  // siguiente. (El 403 es otro caso: ver el test de abajo.)
  const fetchStub = installFetchStub({
    telegram: () =>
      new Response(
        JSON.stringify({
          ok: false,
          error_code: 502,
          description: "Bad Gateway",
        }),
        { status: 502, headers: { "Content-Type": "application/json" } },
      ),
  });

  try {
    const result = await runDigestForAdmin(client, makeArgs());

    assertEquals(result.status, "error");
    assertStringIncludes(result.reason ?? "", "Bad Gateway");

    // bot_digest_registrar con stage=telegram.
    const registro = registros(spy)[0];
    assert(registro, "debió registrar el error");
    assertEquals(registro.params.p_status, "error");
    assertEquals(registro.params.p_sucursal_id, 1);
    const errMeta = registro.params.p_error_meta as Record<string, unknown>;
    assertEquals(errMeta.stage, "telegram");
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

Deno.test("runDigestForAdmin: el usuario bloqueó el bot (403) → la marca queda 'skipped', no se reintenta", async () => {
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

    // 'skipped' y no 'error': un 'error' se retomaría en cada corrida del día y
    // dejaría el gate de integridad.yml rojo para siempre (#1309).
    const registro = registros(spy)[0];
    assert(registro, "debió cerrar la marca");
    assertEquals(registro.params.p_status, "skipped");
    const errMeta = registro.params.p_error_meta as Record<string, unknown>;
    assertEquals(errMeta.stage, "telegram");
    assertStringIncludes(String(errMeta.error), "blocked");
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
  const { client, spy } = createMockSupabase({
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

    // La marca se cierra como 'skipped' con el motivo (#1309): el día ya se
    // evaluó y el gate lo cuenta como hecho.
    const registro = registros(spy)[0];
    assert(registro, "debió cerrar la marca como skipped");
    assertEquals(registro.params.p_status, "skipped");
    assertEquals(registro.params.p_sucursal_id, 1);
    assertEquals(registro.params.p_error_meta, { motivo: "sin_contenido" });
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

    // Hubo reserva (true: la marca en 'error' se retoma) + RPC + fetch + cierre.
    assertEquals(reservas(spy).length, 1);
    assert(
      spy.rpcCalls.some((c) => c.fn === "bot_metricas_admin_dia"),
      "debió reintentar el RPC de métricas",
    );
    assert(fetchStub.spy.calls.some((c) => c.url.includes("api.telegram.org")), "debió mandar");
    const registro = registros(spy)[0];
    assert(registro);
    assertEquals(registro.params.p_status, "ok");
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

Deno.test("runDigestForAdmin: admin sin sucursal (null) → skipped/sin_sucursal, no hace ninguna llamada", async () => {
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
    const result = await runDigestForAdmin(client, { ...makeArgs(), sucursal_id: null });
    // NULL no es "la Red" (#1309): sin sucursal no hay resumen.
    assertEquals(result.status, "skipped");
    assertEquals(result.reason, "sin_sucursal");
    const vencimientosCall = spy.rpcCalls.find((c) => c.fn === "bot_reporte_vencimientos");
    assertEquals(
      vencimientosCall,
      undefined,
      "sin sucursal no hay a quién consultarle vencimientos",
    );
    assertEquals(spy.rpcCalls.length, 0, "no debía llamar a ninguna RPC (ni reservar)");
    assertEquals(fetchStub.spy.calls.length, 0, "no debía mandar nada");
    assertEquals(spy.upserts.length, 0);
    assertEquals(spy.inserts.length, 0);
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

// ============================================================================
// 9. Marca de idempotencia, encabezado con sucursal y casos nuevos (#1309)
// ============================================================================

Deno.test("runDigestForAdmin: el encabezado nombra la sucursal cuando viene sucursal_nombre", async () => {
  setupEnv();
  const { client } = createMockSupabase({
    rpcResponse: { data: FAKE_METRICAS, error: null },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);
  const fetchStub = installFetchStub({ telegram: () => telegramOK() });

  try {
    const result = await runDigestForAdmin(client, {
      ...makeArgs(),
      sucursal_nombre: "Taco Pozo",
    });
    assertEquals(result.status, "ok");
    const tgCall = fetchStub.spy.calls.find((c) => c.url.includes("api.telegram.org"));
    assert(tgCall, "debió llamar a Telegram");
    const primeraLinea = String((tgCall!.body as { text: string }).text).split("\n")[0];
    assertStringIncludes(primeraLinea, "🌅 Resumen");
    assertStringIncludes(primeraLinea, "26/04/2026");
    assert(primeraLinea.endsWith(" · Taco Pozo"), `encabezado: ${primeraLinea}`);
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

Deno.test("encabezadoDigest: con y sin nombre de sucursal", () => {
  assertEquals(
    encabezadoDigest("2026-04-26", "Tucumán"),
    `${encabezadoDigest("2026-04-26")} · Tucumán`,
  );
  assertEquals(encabezadoDigest("2026-04-26", "  "), encabezadoDigest("2026-04-26"));
  assertEquals(encabezadoDigest("2026-04-26", null), encabezadoDigest("2026-04-26"));
  assert(!encabezadoDigest("2026-04-26").includes("·"));
});

Deno.test("runDigestForAdmin: dos reservas — la segunda devuelve false y no manda nada", async () => {
  setupEnv();
  // La primera reserva gana (true) y las siguientes pierden (false), como la
  // base con un INSERT … ON CONFLICT.
  let reservadas = 0;
  const { client, spy } = createMockSupabase({
    rpcResponse: { data: FAKE_METRICAS, error: null },
  });
  // deno-lint-ignore no-explicit-any
  const rpcOriginal = (client as any).rpc.bind(client);
  // deno-lint-ignore no-explicit-any
  (client as any).rpc = (fn: string, params: Record<string, unknown>) => {
    if (fn === "bot_digest_reservar") {
      spy.rpcCalls.push({ fn, params });
      reservadas++;
      return Promise.resolve({ data: reservadas === 1, error: null });
    }
    return rpcOriginal(fn, params);
  };
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);
  const fetchStub = installFetchStub({ telegram: () => telegramOK() });

  try {
    const primera = await runDigestForAdmin(client, makeArgs());
    const segunda = await runDigestForAdmin(client, makeArgs());

    assertEquals(primera.status, "ok");
    assertEquals(segunda.status, "skipped");
    assertEquals(segunda.reason, "already_sent");
    assertEquals(reservas(spy).length, 2);
    assertEquals(
      fetchStub.spy.calls.filter((c) => c.url.includes("api.telegram.org")).length,
      1,
      "sólo la corrida que ganó la reserva manda",
    );
    assertEquals(
      spy.rpcCalls.filter((c) => c.fn === "bot_metricas_admin_dia").length,
      1,
      "la que perdió no pide métricas",
    );
    assertEquals(registros(spy).length, 1, "la que perdió no cierra la marca");
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

Deno.test("runDigestForAdmin: si la reserva falla (la base no contesta) → no manda", async () => {
  setupEnv();
  const { client, spy } = createMockSupabase({
    rpcResponse: { data: FAKE_METRICAS, error: null },
    reservaError: { message: "timeout" },
  });
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);
  const fetchStub = installFetchStub({});

  try {
    const result = await runDigestForAdmin(client, makeArgs());
    assertEquals(result.status, "skipped");
    assertEquals(fetchStub.spy.calls.length, 0, "sin marca no se manda");
    assertEquals(spy.rpcCalls.some((c) => c.fn === "bot_metricas_admin_dia"), false);
    assertEquals(registros(spy).length, 0);
  } finally {
    fetchStub.restore();
    teardownEnv();
  }
});

for (const previo of ["enviando", "skipped"]) {
  Deno.test(`runDigestForAdmin: marca previa '${previo}' → no se retoma ni manda`, async () => {
    setupEnv();
    const { client, spy } = createMockSupabase({ existenteData: { status: previo } });
    // deno-lint-ignore no-explicit-any
    _setServiceRoleClientForTests(client as any);
    const fetchStub = installFetchStub({});

    try {
      const result = await runDigestForAdmin(client, makeArgs());
      assertEquals(result.status, "skipped");
      assertEquals(result.reason, "already_sent");
      assertEquals(fetchStub.spy.calls.length, 0);
      assertEquals(registros(spy).length, 0);
    } finally {
      fetchStub.restore();
      teardownEnv();
    }
  });
}

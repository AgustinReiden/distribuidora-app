// Tests Deno para el aviso de vencimiento crítico (#565).
// Correr con: deno task test (desde supabase/functions/).
//
// Cubrimos:
//   1. formatVencimientosTexto: cero lotes → null.
//   2. formatVencimientosTexto: un lote → texto con producto/cantidad/fecha/días.
//   3. formatVencimientosTexto: varios lotes → ordenados por fecha_vencimiento.
//   4. formatVencimientosTexto: lote ya vencido (dias_restantes negativo).
//   5. fetchLotesCriticos: usa dias_critico_vencimiento de politicas_comerciales.
//   6. fetchLotesCriticos: sin fila de política → usa el default (15).
//   7. fetchLotesCriticos: propaga el error si falla la RPC.
//   8. enviarAvisoVencimiento: ya enviado hoy → skip, sin RPC ni Telegram.
//   9. enviarAvisoVencimiento: sin lotes críticos → skip, no registra idempotencia.
//  10. enviarAvisoVencimiento: con lotes críticos → manda mensaje y registra.
//  11. resolverDestinatariosOperativos: un perfil con dos sucursales asignadas
//      → dos destinatarios (mig 255, PK (perfil, sucursal, fecha) a propósito).
//  12. resolverDestinatariosOperativos: sucursal inactiva → se excluye.

import { assert, assertEquals, assertStringIncludes } from "std/assert/mod.ts";
import type { SupabaseClient } from "@supabase/supabase-js";

import {
  enviarAvisoVencimiento,
  fetchLotesCriticos,
  formatVencimientosTexto,
  resolverDestinatariosOperativos,
  type VencimientoRow,
} from "../telegram-digest/vencimientos.ts";

function makeRow(overrides: Partial<VencimientoRow> = {}): VencimientoRow {
  return {
    producto_nombre: "Fideos 500g",
    producto_codigo: "FID-500",
    cantidad_restante: 24,
    fecha_vencimiento: "2026-09-20",
    dias_restantes: 5,
    ...overrides,
  };
}

// ============================================================================
// formatVencimientosTexto
// ============================================================================

Deno.test("formatVencimientosTexto: cero lotes → null", () => {
  assertEquals(formatVencimientosTexto([]), null);
});

Deno.test("formatVencimientosTexto: un lote → incluye producto, cantidad, fecha y días", () => {
  const texto = formatVencimientosTexto([makeRow()]);
  assert(texto !== null);
  assertStringIncludes(texto!, "Fideos 500g");
  assertStringIncludes(texto!, "FID-500");
  assertStringIncludes(texto!, "24 u.");
  assertStringIncludes(texto!, "20/09/2026");
  assertStringIncludes(texto!, "vence en 5d");
});

Deno.test("formatVencimientosTexto: varios lotes → ordenados por fecha_vencimiento ASC", () => {
  const rows = [
    makeRow({ producto_nombre: "C", fecha_vencimiento: "2026-09-25", dias_restantes: 10 }),
    makeRow({ producto_nombre: "A", fecha_vencimiento: "2026-09-18", dias_restantes: 3 }),
    makeRow({ producto_nombre: "B", fecha_vencimiento: "2026-09-20", dias_restantes: 5 }),
  ];
  const texto = formatVencimientosTexto(rows)!;
  const posA = texto.indexOf("A");
  const posB = texto.indexOf("B");
  const posC = texto.indexOf("C");
  assert(posA < posB && posB < posC, `orden incorrecto: ${texto}`);
});

Deno.test("formatVencimientosTexto: misma fecha → desempata por nombre", () => {
  const rows = [
    makeRow({ producto_nombre: "Zapallo", fecha_vencimiento: "2026-09-20", dias_restantes: 5 }),
    makeRow({ producto_nombre: "Arroz", fecha_vencimiento: "2026-09-20", dias_restantes: 5 }),
  ];
  const texto = formatVencimientosTexto(rows)!;
  assert(texto.indexOf("Arroz") < texto.indexOf("Zapallo"), `orden incorrecto: ${texto}`);
});

Deno.test("formatVencimientosTexto: lote ya vencido → 'vencido hace Nd'", () => {
  const texto = formatVencimientosTexto([makeRow({ dias_restantes: -3 })])!;
  assertStringIncludes(texto, "vencido hace 3d");
});

Deno.test("formatVencimientosTexto: vence hoy → 'vence hoy'", () => {
  const texto = formatVencimientosTexto([makeRow({ dias_restantes: 0 })])!;
  assertStringIncludes(texto, "vence hoy");
});

// ============================================================================
// fetchLotesCriticos
// ============================================================================

interface MockOpts {
  politicaData?: Record<string, unknown> | null;
  politicaError?: { message: string } | null;
  rpcResponse?: { data: unknown; error: { message: string } | null };
}

function createMockSupabase(opts: MockOpts = {}) {
  const rpcCalls: Array<{ fn: string; params: Record<string, unknown> }> = [];

  // deno-lint-ignore no-explicit-any
  const client: any = {
    from(table: string) {
      // deno-lint-ignore no-explicit-any
      const builder: any = {
        select(_cols: string) {
          return builder;
        },
        eq(_col: string, _val: unknown) {
          return builder;
        },
        maybeSingle() {
          if (table === "politicas_comerciales") {
            return Promise.resolve({
              data: opts.politicaData ?? null,
              error: opts.politicaError ?? null,
            });
          }
          return Promise.resolve({ data: null, error: null });
        },
      };
      return builder;
    },
    rpc(fn: string, params: Record<string, unknown>) {
      rpcCalls.push({ fn, params });
      return Promise.resolve(opts.rpcResponse ?? { data: [], error: null });
    },
  };
  return { client: client as SupabaseClient, rpcCalls };
}

Deno.test("fetchLotesCriticos: usa dias_critico_vencimiento de la política", async () => {
  const { client, rpcCalls } = createMockSupabase({
    politicaData: { dias_critico_vencimiento: 7 },
    rpcResponse: { data: [makeRow()], error: null },
  });

  const rows = await fetchLotesCriticos(client, 2);

  assertEquals(rpcCalls.length, 1);
  assertEquals(rpcCalls[0].fn, "bot_reporte_vencimientos");
  assertEquals(rpcCalls[0].params.p_sucursal_id, 2);
  assertEquals(rpcCalls[0].params.p_dias_horizonte, 7);
  assertEquals(rows.length, 1);
});

Deno.test("fetchLotesCriticos: sin fila de política → usa el default (15)", async () => {
  const { client, rpcCalls } = createMockSupabase({
    politicaData: null,
    rpcResponse: { data: [], error: null },
  });

  await fetchLotesCriticos(client, 3);

  assertEquals(rpcCalls[0].params.p_dias_horizonte, 15);
});

Deno.test("fetchLotesCriticos: propaga el error si falla la RPC", async () => {
  const { client } = createMockSupabase({
    politicaData: { dias_critico_vencimiento: 15 },
    rpcResponse: { data: null, error: { message: "permission denied" } },
  });

  let threw = false;
  try {
    await fetchLotesCriticos(client, 1);
  } catch (err) {
    threw = true;
    assertStringIncludes(err instanceof Error ? err.message : String(err), "permission denied");
  }
  assert(threw, "debió lanzar");
});

Deno.test("fetchLotesCriticos: propaga el error si falla la lectura de la política", async () => {
  const { client } = createMockSupabase({
    politicaError: { message: "connection lost" },
  });

  let threw = false;
  try {
    await fetchLotesCriticos(client, 1);
  } catch (err) {
    threw = true;
    assertStringIncludes(err instanceof Error ? err.message : String(err), "connection lost");
  }
  assert(threw, "debió lanzar");
});

// ============================================================================
// Mock genérico para enviarAvisoVencimiento / resolverDestinatariosOperativos
// ============================================================================

interface FullMockOpts {
  /** bot_avisos_vencimiento_enviados.select(...).maybeSingle() → fila existente o null. */
  avisoExistente?: Record<string, unknown> | null;
  /** politicas_comerciales.select(...).maybeSingle(). */
  politicaData?: Record<string, unknown> | null;
  /** bot_reporte_vencimientos RPC. */
  rpcResponse?: { data: unknown; error: { message: string } | null };
  /** bot_usuarios.select(...) (sin maybeSingle) → lista de usuarios operativos. */
  usuariosOperativos?: unknown[];
  /** usuario_sucursales.select(...) por perfil_id → lista de sucursales asignadas. */
  sucursalesPorPerfil?: Record<string, unknown[]>;
}

interface FullMockSpy {
  inserts: Array<{ table: string; row: Record<string, unknown> }>;
  rpcCalls: Array<{ fn: string; params: Record<string, unknown> }>;
}

function createFullMockSupabase(opts: FullMockOpts = {}): { client: SupabaseClient; spy: FullMockSpy } {
  const spy: FullMockSpy = { inserts: [], rpcCalls: [] };

  function makeBuilder(table: string) {
    const eqs: Array<{ col: string; val: unknown }> = [];
    // deno-lint-ignore no-explicit-any
    const builder: any = {
      select(_cols: string) {
        return builder;
      },
      eq(col: string, val: unknown) {
        eqs.push({ col, val });
        return builder;
      },
      in(col: string, val: unknown) {
        eqs.push({ col, val });
        return builder;
      },
      maybeSingle() {
        if (table === "bot_avisos_vencimiento_enviados") {
          return Promise.resolve({ data: opts.avisoExistente ?? null, error: null });
        }
        if (table === "politicas_comerciales") {
          return Promise.resolve({ data: opts.politicaData ?? null, error: null });
        }
        return Promise.resolve({ data: null, error: null });
      },
      insert(row: Record<string, unknown>) {
        spy.inserts.push({ table, row });
        return Promise.resolve({ error: null });
      },
      // Query awaited directamente (sin .maybeSingle()): bot_usuarios y
      // usuario_sucursales. El builder es thenable.
      then(
        resolve: (v: { data: unknown; error: unknown }) => void,
        reject: (e: unknown) => void,
      ) {
        let result: { data: unknown; error: unknown };
        if (table === "bot_usuarios") {
          result = { data: opts.usuariosOperativos ?? [], error: null };
        } else if (table === "usuario_sucursales") {
          const usuarioIdEq = eqs.find((e) => e.col === "usuario_id");
          const perfilId = usuarioIdEq ? String(usuarioIdEq.val) : "";
          result = { data: opts.sucursalesPorPerfil?.[perfilId] ?? [], error: null };
        } else {
          result = { data: null, error: null };
        }
        return Promise.resolve(result).then(resolve, reject);
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
      return Promise.resolve(opts.rpcResponse ?? { data: [], error: null });
    },
  };
  return { client: client as SupabaseClient, spy };
}

function installTelegramFetchStub(): {
  calls: Array<{ chatId: number; text: string }>;
  restore: () => void;
} {
  const original = globalThis.fetch;
  const calls: Array<{ chatId: number; text: string }> = [];
  Deno.env.set("TELEGRAM_BOT_TOKEN", "test-token");

  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    if (!url.includes("api.telegram.org")) {
      throw new Error(`unexpected fetch URL: ${url}`);
    }
    const body = init?.body ? JSON.parse(init.body as string) : {};
    calls.push({ chatId: body.chat_id, text: body.text });
    return Promise.resolve(
      new Response(JSON.stringify({ ok: true, result: { message_id: 1 } }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
  }) as typeof fetch;

  return {
    calls,
    restore: () => {
      globalThis.fetch = original;
      Deno.env.delete("TELEGRAM_BOT_TOKEN");
    },
  };
}

// ============================================================================
// enviarAvisoVencimiento
// ============================================================================

const DESTINATARIO = {
  telegram_user_id: 99,
  perfil_id: "22222222-2222-2222-2222-222222222222",
  sucursal_id: 2,
};

Deno.test("enviarAvisoVencimiento: ya enviado hoy → skip, sin RPC ni Telegram", async () => {
  const { client, spy } = createFullMockSupabase({
    avisoExistente: { perfil_id: DESTINATARIO.perfil_id },
  });
  const fetchStub = installTelegramFetchStub();

  try {
    const result = await enviarAvisoVencimiento(client, DESTINATARIO, "2026-09-15");

    assertEquals(result.status, "skipped");
    assertEquals(result.reason, "already_sent");
    assertEquals(spy.rpcCalls.length, 0, "no debía llamar a bot_reporte_vencimientos");
    assertEquals(fetchStub.calls.length, 0, "no debía llamar a Telegram");
    assertEquals(spy.inserts.length, 0, "no debía insertar");
  } finally {
    fetchStub.restore();
  }
});

Deno.test("enviarAvisoVencimiento: sin lotes críticos → skip, no registra idempotencia", async () => {
  const { client, spy } = createFullMockSupabase({
    avisoExistente: null,
    politicaData: { dias_critico_vencimiento: 15 },
    rpcResponse: { data: [], error: null },
  });
  const fetchStub = installTelegramFetchStub();

  try {
    const result = await enviarAvisoVencimiento(client, DESTINATARIO, "2026-09-15");

    assertEquals(result.status, "skipped");
    assertEquals(result.reason, "sin_lotes_criticos");
    assertEquals(fetchStub.calls.length, 0, "no debía llamar a Telegram");
    assertEquals(spy.inserts.length, 0, "no debía registrar idempotencia sin envío");
  } finally {
    fetchStub.restore();
  }
});

Deno.test("enviarAvisoVencimiento: con lotes críticos → manda mensaje y registra idempotencia", async () => {
  const { client, spy } = createFullMockSupabase({
    avisoExistente: null,
    politicaData: { dias_critico_vencimiento: 15 },
    rpcResponse: { data: [makeRow({ producto_nombre: "Yogur" })], error: null },
  });
  const fetchStub = installTelegramFetchStub();

  try {
    const result = await enviarAvisoVencimiento(client, DESTINATARIO, "2026-09-15");

    assertEquals(result.status, "sent");
    assertEquals(fetchStub.calls.length, 1);
    assertEquals(fetchStub.calls[0].chatId, DESTINATARIO.telegram_user_id);
    assertStringIncludes(fetchStub.calls[0].text, "Yogur");

    const insert = spy.inserts.find((i) => i.table === "bot_avisos_vencimiento_enviados");
    assert(insert, "debió registrar en bot_avisos_vencimiento_enviados");
    assertEquals(insert!.row.perfil_id, DESTINATARIO.perfil_id);
    assertEquals(insert!.row.sucursal_id, DESTINATARIO.sucursal_id);
    assertEquals(insert!.row.fecha, "2026-09-15");
  } finally {
    fetchStub.restore();
  }
});

// ============================================================================
// resolverDestinatariosOperativos
// ============================================================================

Deno.test("resolverDestinatariosOperativos: un perfil con dos sucursales → dos destinatarios", async () => {
  const perfilId = "33333333-3333-3333-3333-333333333333";
  const { client } = createFullMockSupabase({
    usuariosOperativos: [
      { telegram_user_id: 7, perfil_id: perfilId, perfiles: { rol: "encargado", activo: true } },
    ],
    sucursalesPorPerfil: {
      [perfilId]: [
        { sucursal_id: 1, sucursales: { id: 1, activa: true } },
        { sucursal_id: 2, sucursales: { id: 2, activa: true } },
      ],
    },
  });

  const destinatarios = await resolverDestinatariosOperativos(client);

  assertEquals(destinatarios.length, 2);
  assertEquals(destinatarios.map((d) => d.sucursal_id).sort(), [1, 2]);
  for (const d of destinatarios) {
    assertEquals(d.perfil_id, perfilId);
    assertEquals(d.telegram_user_id, 7);
  }
});

Deno.test("resolverDestinatariosOperativos: sucursal inactiva se excluye", async () => {
  const perfilId = "44444444-4444-4444-4444-444444444444";
  const { client } = createFullMockSupabase({
    usuariosOperativos: [
      { telegram_user_id: 8, perfil_id: perfilId, perfiles: { rol: "deposito", activo: true } },
    ],
    sucursalesPorPerfil: {
      [perfilId]: [
        { sucursal_id: 1, sucursales: { id: 1, activa: true } },
        { sucursal_id: 5, sucursales: { id: 5, activa: false } },
      ],
    },
  });

  const destinatarios = await resolverDestinatariosOperativos(client);

  assertEquals(destinatarios.length, 1);
  assertEquals(destinatarios[0].sucursal_id, 1);
});

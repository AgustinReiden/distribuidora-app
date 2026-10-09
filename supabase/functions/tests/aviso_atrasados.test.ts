// Mig 325: aviso semanal de clientes atrasados para preventistas.
//
// Lo que importa: no usa ningún modelo, manda la lista con un botón de visita
// por cliente, no manda nada si no hay atrasados, y una corrida repetida en la
// misma fecha no duplica el mensaje.

import { assert, assertEquals, assertStringIncludes } from "std/assert/mod.ts";
import type { SupabaseClient } from "@supabase/supabase-js";
import { formatAvisoAtrasados, runAvisoAtrasados, runAvisosAtrasados } from "../telegram-digest/atrasados.ts";
import { normalizarDatos } from "../telegram-digest/preventista.ts";
import { _setServiceRoleClientForTests } from "../_shared/supabase.ts";

const ATRASADOS = {
  clientes_en_cartera: 187,
  atrasados: 12,
  monto_mensual_en_riesgo: 659857.2,
  clientes: [
    { cliente_id: 11, nombre: "Despensa Rita", dias_sin_comprar: 16, frecuencia_dias: 7, monto_mensual: 128251.67 },
    { cliente_id: 12, nombre: "Kiosco_Gladys", dias_sin_comprar: 17, frecuencia_dias: 8, monto_mensual: 54868.33 },
  ],
};

const DEST = { telegram_user_id: 555, perfil_id: "44444444-4444-4444-4444-444444444444", sucursal_id: 1 };

function mockSb(opts: {
  previo?: string | null;
  rpc?: Record<string, { data: unknown; error: { message: string } | null }>;
} = {}) {
  const upserts: Array<Record<string, unknown>> = [];
  const rpcs: Array<{ fn: string; params: Record<string, unknown> }> = [];
  // deno-lint-ignore no-explicit-any
  const b: any = {
    select: () => b,
    eq: () => b,
    maybeSingle: () => Promise.resolve({ data: opts.previo ? { status: opts.previo } : null, error: null }),
    upsert: (row: Record<string, unknown>) => {
      upserts.push(row);
      return Promise.resolve({ error: null });
    },
    insert: () => Promise.resolve({ error: null }),
  };
  // deno-lint-ignore no-explicit-any
  const client: any = {
    from: () => b,
    rpc: (fn: string, params: Record<string, unknown>) => {
      rpcs.push({ fn, params });
      return Promise.resolve(opts.rpc?.[fn] ?? { data: [], error: null });
    },
  };
  return { client: client as SupabaseClient, upserts, rpcs };
}

function stubFetch() {
  const original = globalThis.fetch;
  const calls: Array<{ url: string; body: Record<string, unknown> | null }> = [];
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), body: init?.body ? JSON.parse(init.body as string) : null });
    return Promise.resolve(new Response(JSON.stringify({ ok: true, result: { message_id: 1 } }), { status: 200 }));
  }) as typeof fetch;
  return { calls, restore: () => (globalThis.fetch = original) };
}

function conEnv(fn: () => Promise<void>) {
  return async () => {
    Deno.env.set("TELEGRAM_BOT_TOKEN", "t");
    try {
      await fn();
    } finally {
      Deno.env.delete("TELEGRAM_BOT_TOKEN");
      _setServiceRoleClientForTests(null);
    }
  };
}

Deno.test("aviso: manda la lista sin modelo, con un botón de visita por cliente", conEnv(async () => {
  const { client, upserts, rpcs } = mockSb({ rpc: { bot_clientes_atrasados: { data: ATRASADOS, error: null } } });
  _setServiceRoleClientForTests(client as never);
  const f = stubFetch();
  try {
    const r = await runAvisoAtrasados(client, DEST, "2026-10-12");
    assertEquals(r.status, "ok");
    assertEquals(f.calls.filter((c) => !c.url.includes("api.telegram.org")).length, 0);
    const tg = f.calls.find((c) => c.url.includes("sendMessage"))!;
    assertEquals(tg.body?.chat_id, 555);
    assertEquals(tg.body?.parse_mode, undefined);
    const kb = tg.body?.reply_markup as { inline_keyboard: Array<Array<{ callback_data: string }>> };
    assertEquals(kb.inline_keyboard.map((f) => f[0].callback_data), ["v1:visita:11", "v1:visita:12"]);
    // Su cartera, como preventista: nunca la sucursal entera.
    assertEquals(rpcs[0].params.p_rol, "preventista");
    assertEquals(rpcs[0].params.p_perfil_id, DEST.perfil_id);
    assertEquals(upserts.at(-1)?.status, "ok");
  } finally {
    f.restore();
  }
}));

Deno.test("aviso: sin clientes atrasados no manda nada y lo registra", conEnv(async () => {
  const { client, upserts } = mockSb({
    rpc: {
      bot_clientes_atrasados: {
        data: { clientes_en_cartera: 50, atrasados: 0, monto_mensual_en_riesgo: 0, clientes: [] },
        error: null,
      },
    },
  });
  const f = stubFetch();
  try {
    const r = await runAvisoAtrasados(client, DEST, "2026-10-12");
    assertEquals(r.status, "skipped");
    assertEquals(f.calls.length, 0);
    assertEquals(upserts.at(-1)?.status, "skipped");
  } finally {
    f.restore();
  }
}));

Deno.test("aviso: si ya salió en la fecha, la corrida siguiente no lo repite", conEnv(async () => {
  const { client, rpcs } = mockSb({ previo: "ok" });
  const f = stubFetch();
  try {
    const r = await runAvisoAtrasados(client, DEST, "2026-10-12");
    assertEquals(r.status, "skipped");
    assertEquals(rpcs.length, 0);
    assertEquals(f.calls.length, 0);
  } finally {
    f.restore();
  }
}));

Deno.test("aviso: un error de la RPC queda registrado y no manda mensaje", conEnv(async () => {
  const { client, upserts } = mockSb({ rpc: { bot_clientes_atrasados: { data: null, error: { message: "timeout" } } } });
  const f = stubFetch();
  try {
    const r = await runAvisoAtrasados(client, DEST, "2026-10-12");
    assertEquals(r.status, "error");
    assertEquals(f.calls.length, 0);
    assertEquals((upserts.at(-1)?.error_meta as Record<string, unknown>).stage, "datos");
  } finally {
    f.restore();
  }
}));

Deno.test("runAvisosAtrasados: pregunta a quién le toca con la hora y el día de la corrida", conEnv(async () => {
  const { client, rpcs } = mockSb({
    rpc: {
      bot_aviso_atrasados_destinatarios: { data: [DEST], error: null },
      bot_clientes_atrasados: { data: ATRASADOS, error: null },
    },
  });
  const f = stubFetch();
  try {
    const r = await runAvisosAtrasados(client, 8, 1, "2026-10-12");
    assertEquals(rpcs[0], { fn: "bot_aviso_atrasados_destinatarios", params: { p_hora: 8, p_dow: 1 } });
    assertEquals(r.map((x) => x.status), ["ok"]);
  } finally {
    f.restore();
  }
}));

Deno.test("formatAvisoAtrasados: explica qué es 'atrasado' y lista con la plata", () => {
  const t = formatAvisoAtrasados(normalizarDatos({ mis_atrasados: ATRASADOS }).mis_atrasados);
  assertStringIncludes(t, "Clientes que dejaron de comprar");
  assertStringIncludes(t, "el doble de lo que suelen tardar");
  assertStringIncludes(t, "12 clientes atrasados");
  assertStringIncludes(t, "Despensa Rita: 16 días sin comprar (compraba cada ~7)");
  assertStringIncludes(t, "…y 10 más: /atrasados");
  assert(t.includes("Tocá un cliente"));
});

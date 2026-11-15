// #1552: el bot respeta el alcance que el usuario tiene en la app.
//
//   B-1 · el depósito no lee clientes: ni `buscar_cliente` ni `ficha_cliente`
//         (y con eso ni el modelo, ni el botón "Ver ficha", ni `/cliente`). El
//         transportista sí, como en la app.
//   B-3 · el aviso de atrasados va a las sucursales vivas: la RPC devuelve una
//         fila por sucursal y las de un mismo perfil van en un solo mensaje,
//         con una marca de enviado.
//   B-4 · cada fila del registro del aviso lleva su sucursal en el meta.
// (B-2, el resumen del recorrido sin fecha, está en tools.test.ts.)

import { assert, assertEquals, assertStringIncludes } from "std/assert/mod.ts";
import type { SupabaseClient } from "@supabase/supabase-js";
import { _resetRegisterFlagForTests, registerAllTools } from "../_shared/tools/index.ts";
import { _clearToolsForTests, getToolsForRole, invokeTool } from "../_shared/tools/registry.ts";
import type { ToolContext } from "../_shared/tools/base.ts";
import { clienteCommand } from "../telegram-webhook/commands/cliente.ts";
import { runAvisosAtrasados } from "../telegram-digest/atrasados.ts";
import { _setServiceRoleClientForTests } from "../_shared/supabase.ts";

function registro() {
  _clearToolsForTests();
  _resetRegisterFlagForTests();
  registerAllTools();
}

Deno.test("B-1: el depósito no tiene las tools de clientes; el transportista sí", () => {
  registro();
  const deposito = getToolsForRole(["deposito"]).map((t) => t.name);
  assert(!deposito.includes("buscar_cliente"), deposito.join(", "));
  assert(!deposito.includes("ficha_cliente"), deposito.join(", "));
  // Sigue con lo suyo: productos.
  assert(deposito.includes("buscar_producto"));

  const transportista = getToolsForRole(["transportista"]).map((t) => t.name);
  assert(transportista.includes("buscar_cliente"));
  assert(transportista.includes("ficha_cliente"));
});

Deno.test("B-1: ficha_cliente y buscar_cliente como depósito rebotan sin tocar la base", async () => {
  registro();
  Deno.env.set("BOT_AUDIT_DISABLED", "1");
  try {
    const llamadas: string[] = [];
    const sb = {
      from: (t: string) => {
        llamadas.push(`from:${t}`);
        throw new Error("no debería leer nada");
      },
      rpc: (fn: string) => {
        llamadas.push(`rpc:${fn}`);
        throw new Error("no debería llamar a ninguna RPC");
      },
    };
    const ctx = {
      perfil_id: "dep-uuid",
      rol: "deposito",
      roles: ["deposito"],
      telegram_user_id: 1,
      sucursal_id: 1,
      supabase: sb,
    } as unknown as ToolContext;
    const ficha = await invokeTool("ficha_cliente", { cliente_id: 33 }, ctx);
    assertEquals(ficha, { ok: false, error: "permiso_denegado" });
    const busca = await invokeTool("buscar_cliente", { q: "almacen" }, ctx);
    assertEquals(busca, { ok: false, error: "permiso_denegado" });
    assertEquals(llamadas, []);
  } finally {
    Deno.env.delete("BOT_AUDIT_DISABLED");
  }
});

Deno.test("B-1: /cliente no es para el depósito, sí para el transportista", () => {
  assert(Array.isArray(clienteCommand.scope), "el scope de /cliente es una lista de roles");
  const scope = clienteCommand.scope as ReadonlyArray<string>;
  assert(!scope.includes("deposito"));
  for (const rol of ["admin", "encargado", "preventista", "transportista"]) {
    assert(scope.includes(rol), rol);
  }
});

// ---------------------------------------------------------------- B-3 / B-4 --

const ATRASADOS_A = {
  clientes_en_cartera: 10,
  atrasados: 1,
  monto_mensual_en_riesgo: 1000,
  clientes: [{
    cliente_id: 11,
    nombre: "Despensa Rita",
    dias_sin_comprar: 16,
    frecuencia_dias: 7,
    monto_mensual: 1000,
  }],
};
const ATRASADOS_B = {
  clientes_en_cartera: 5,
  atrasados: 1,
  monto_mensual_en_riesgo: 500,
  clientes: [{
    cliente_id: 21,
    nombre: "Kiosco Gladys",
    dias_sin_comprar: 30,
    frecuencia_dias: 10,
    monto_mensual: 500,
  }],
};
const PERFIL = "44444444-4444-4444-4444-444444444444";

function mockAviso(destinatarios: unknown[], porSucursal: Record<number, unknown>) {
  const rpcs: Array<{ fn: string; params: Record<string, unknown> }> = [];
  const auditoria: Array<Record<string, unknown>> = [];
  // deno-lint-ignore no-explicit-any
  const b: any = {
    upsert: () => Promise.resolve({ error: null }),
    insert: (row: Record<string, unknown>) => {
      auditoria.push(row);
      return Promise.resolve({ error: null });
    },
  };
  const client = {
    from: () => b,
    rpc: (fn: string, params: Record<string, unknown>) => {
      rpcs.push({ fn, params });
      if (fn === "bot_aviso_atrasados_destinatarios") {
        return Promise.resolve({ data: destinatarios, error: null });
      }
      if (fn === "bot_aviso_atrasados_reservar") {
        return Promise.resolve({ data: true, error: null });
      }
      if (fn === "bot_clientes_atrasados") {
        return Promise.resolve({ data: porSucursal[params.p_sucursal_id as number], error: null });
      }
      return Promise.resolve({ data: null, error: null });
    },
  } as unknown as SupabaseClient;
  return { client, rpcs, auditoria };
}

function stubFetch() {
  const original = globalThis.fetch;
  const calls: Array<{ url: string; body: Record<string, unknown> | null }> = [];
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), body: init?.body ? JSON.parse(init.body as string) : null });
    return Promise.resolve(
      new Response(JSON.stringify({ ok: true, result: { message_id: 1 } }), { status: 200 }),
    );
  }) as typeof fetch;
  return { calls, restore: () => (globalThis.fetch = original) };
}

async function conEnv(fn: () => Promise<void>) {
  Deno.env.set("TELEGRAM_BOT_TOKEN", "t");
  try {
    await fn();
  } finally {
    Deno.env.delete("TELEGRAM_BOT_TOKEN");
    _setServiceRoleClientForTests(null);
  }
}

Deno.test("B-3: con dos sucursales, una marca y un mensaje con las dos listas", () =>
  conEnv(async () => {
    const { client, rpcs, auditoria } = mockAviso(
      [
        { telegram_user_id: 555, perfil_id: PERFIL, sucursal_id: 1, sucursal_nombre: "Tucumán" },
        { telegram_user_id: 555, perfil_id: PERFIL, sucursal_id: 2, sucursal_nombre: "Taco Pozo" },
      ],
      { 1: ATRASADOS_A, 2: ATRASADOS_B },
    );
    _setServiceRoleClientForTests(client as never);
    const f = stubFetch();
    try {
      const r = await runAvisosAtrasados(client, 8, 1, "2026-11-16");
      assertEquals(r, [{ perfil_id: PERFIL, status: "ok" }]);
      assertEquals(rpcs.filter((c) => c.fn === "bot_aviso_atrasados_reservar").length, 1);
      assertEquals(
        rpcs.filter((c) => c.fn === "bot_clientes_atrasados").map((c) => c.params.p_sucursal_id),
        [1, 2],
      );
      const envios = f.calls.filter((c) => c.url.includes("sendMessage"));
      assertEquals(envios.length, 1);
      const texto = String(envios[0].body?.text);
      assertStringIncludes(texto, "🏢 Tucumán");
      assertStringIncludes(texto, "🏢 Taco Pozo");
      assertStringIncludes(texto, "Despensa Rita");
      assertStringIncludes(texto, "Kiosco Gladys");
      const kb = envios[0].body?.reply_markup as {
        inline_keyboard: Array<Array<{ callback_data: string }>>;
      };
      assertEquals(kb.inline_keyboard.flat().map((b) => b.callback_data), [
        "v1:visita:11",
        "v1:visita:21",
      ]);

      // B-4: una fila del registro por sucursal, cada una con la suya y su lista.
      assertEquals(auditoria.length, 2);
      assertEquals(
        auditoria.map((a) => (a.resultado_meta as Record<string, unknown>).sucursal_id),
        [1, 2],
      );
      assertStringIncludes(String(auditoria[0].texto_bot), "Despensa Rita");
      assert(!String(auditoria[0].texto_bot).includes("Kiosco Gladys"));
      assertStringIncludes(String(auditoria[1].texto_bot), "Kiosco Gladys");
      assert(!String(auditoria[1].texto_bot).includes("Despensa Rita"));
    } finally {
      f.restore();
    }
  }));

Deno.test("B-3: con una sola sucursal, el mensaje de siempre (sin nombre) y la sucursal en el registro", () =>
  conEnv(async () => {
    const { client, auditoria } = mockAviso(
      [{ telegram_user_id: 555, perfil_id: PERFIL, sucursal_id: 2, sucursal_nombre: "Taco Pozo" }],
      { 2: ATRASADOS_B },
    );
    _setServiceRoleClientForTests(client as never);
    const f = stubFetch();
    try {
      const r = await runAvisosAtrasados(client, 8, 1, "2026-11-16");
      assertEquals(r.map((x) => x.status), ["ok"]);
      const texto = String(f.calls.find((c) => c.url.includes("sendMessage"))?.body?.text);
      assert(!texto.includes("🏢"), texto);
      assertStringIncludes(texto, "Kiosco Gladys");
      assertEquals(auditoria.length, 1);
      assertEquals((auditoria[0].resultado_meta as Record<string, unknown>).sucursal_id, 2);
      assertEquals(auditoria[0].texto_bot, texto);
    } finally {
      f.restore();
    }
  }));

Deno.test("B-3: si una de sus sucursales no tiene atrasados, va sólo la otra", () =>
  conEnv(async () => {
    const { client } = mockAviso(
      [
        { telegram_user_id: 555, perfil_id: PERFIL, sucursal_id: 1, sucursal_nombre: "Tucumán" },
        { telegram_user_id: 555, perfil_id: PERFIL, sucursal_id: 2, sucursal_nombre: "Taco Pozo" },
      ],
      {
        1: { clientes_en_cartera: 3, atrasados: 0, monto_mensual_en_riesgo: 0, clientes: [] },
        2: ATRASADOS_B,
      },
    );
    _setServiceRoleClientForTests(client as never);
    const f = stubFetch();
    try {
      await runAvisosAtrasados(client, 8, 1, "2026-11-16");
      const texto = String(f.calls.find((c) => c.url.includes("sendMessage"))?.body?.text);
      assertStringIncludes(texto, "🏢 Taco Pozo");
      assert(!texto.includes("Tucumán"), texto);
    } finally {
      f.restore();
    }
  }));

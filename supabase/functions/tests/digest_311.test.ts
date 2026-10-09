// Mig 311: el resumen de la mañana del preventista, la plata en riesgo por
// preventista del admin y el botón "🧾 <cliente>" (resumen de visita).
//
// Lo que importa probar:
//   * el resumen del preventista NO llama a Gemini (cuesta cero de IA);
//   * sólo muestra las secciones prendidas;
//   * los botones van al callback `visita`, no a la ficha;
//   * la sección de riesgo del admin se pega sin modelo y desaparece sin
//     atrasados;
//   * idempotencia y registro de errores, igual que el del admin.

import { assert, assertEquals, assertStringIncludes } from "std/assert/mod.ts";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  formatDigestPreventista,
  normalizarDatos,
  runDigestForPreventista,
} from "../telegram-digest/preventista.ts";
import { formatRiesgoTexto } from "../telegram-digest/riesgo.ts";
import { runDigestForAdmin } from "../telegram-digest/digest.ts";
import {
  incluyeRiesgoPreventistas,
  tieneSeccionesDeMetricas,
} from "../telegram-digest/secciones.ts";
import { buildVisitaKeyboard } from "../_shared/telegram-keyboards.ts";
import { formatResumenVisita } from "../telegram-webhook/formatters/resumen-visita.ts";
import { _setServiceRoleClientForTests } from "../_shared/supabase.ts";

// ============================================================================
// Mocks
// ============================================================================

interface Spy {
  upserts: Array<{ table: string; row: Record<string, unknown> }>;
  rpcCalls: Array<{ fn: string; params: Record<string, unknown> }>;
}

function mockSupabase(opts: {
  existente?: Record<string, unknown> | null;
  rpc?: Record<string, { data: unknown; error: { message: string } | null }>;
} = {}): { client: SupabaseClient; spy: Spy } {
  const spy: Spy = { upserts: [], rpcCalls: [] };
  // deno-lint-ignore no-explicit-any
  const builder = (table: string): any => {
    // deno-lint-ignore no-explicit-any
    const b: any = {
      select: () => b,
      eq: () => b,
      maybeSingle: () =>
        Promise.resolve({
          data: table === "bot_digests_enviados" ? opts.existente ?? null : null,
          error: null,
        }),
      upsert: (row: Record<string, unknown>) => {
        spy.upserts.push({ table, row });
        return Promise.resolve({ error: null });
      },
      insert: () => Promise.resolve({ error: null }),
    };
    return b;
  };
  // deno-lint-ignore no-explicit-any
  const client: any = {
    from: (t: string) => builder(t),
    rpc: (fn: string, params: Record<string, unknown>) => {
      spy.rpcCalls.push({ fn, params });
      return Promise.resolve(opts.rpc?.[fn] ?? { data: [], error: null });
    },
  };
  return { client: client as SupabaseClient, spy };
}

function stubFetch(telegramFalla = false) {
  const original = globalThis.fetch;
  const calls: Array<{ url: string; body: Record<string, unknown> | null }> = [];
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    const body = init?.body ? JSON.parse(init.body as string) : null;
    calls.push({ url, body });
    if (url.includes("generativelanguage.googleapis.com") || url.includes("api.openai.com")) {
      throw new Error(`no debe llamar a un modelo: ${url}`);
    }
    if (url.includes("api.telegram.org")) {
      if (telegramFalla) return Promise.resolve(new Response("{}", { status: 500 }));
      return Promise.resolve(
        new Response(JSON.stringify({ ok: true, result: { message_id: 1 } }), { status: 200 }),
      );
    }
    throw new Error(`fetch inesperado: ${url}`);
  }) as typeof fetch;
  return { calls, restore: () => (globalThis.fetch = original) };
}

function setupEnv() {
  Deno.env.set("TELEGRAM_BOT_TOKEN", "t");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "s");
}

function teardownEnv() {
  Deno.env.delete("TELEGRAM_BOT_TOKEN");
  Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY");
  _setServiceRoleClientForTests(null);
}

const DATOS = {
  fecha: "2026-10-07",
  mis_ventas: {
    dia_tomados_pedidos: 7,
    dia_tomados_total: 182500,
    mes_total: 1250300,
    mes_pedidos: 41,
    mes_clientes: 28,
  },
  mis_atrasados: {
    clientes_en_cartera: 187,
    atrasados: 21,
    monto_mensual_en_riesgo: 737507.2,
    clientes: [
      {
        cliente_id: 11,
        nombre: "Almacén Silvio",
        dias_sin_comprar: 24,
        frecuencia_dias: 7,
        monto_mensual: 98000,
      },
      {
        cliente_id: 12,
        nombre: "Kiosco_Norte",
        dias_sin_comprar: 40,
        frecuencia_dias: 14,
        monto_mensual: 0,
      },
    ],
  },
};

const ARGS = {
  telegram_user_id: 77,
  perfil_id: "22222222-2222-2222-2222-222222222222",
  sucursal_id: 1,
  fecha: "2026-10-07",
  secciones: ["mis_atrasados", "mis_ventas"],
};

// ============================================================================
// 1. Formatter del resumen del preventista
// ============================================================================

Deno.test("formatDigestPreventista: pedidos de ayer, venta del mes y los atrasados con su plata", () => {
  const t = formatDigestPreventista("2026-10-07", normalizarDatos(DATOS), [
    "mis_ventas",
    "mis_atrasados",
  ])!;
  assertStringIncludes(t, "Tu resumen");
  // Lo de ayer son pedidos TOMADOS: la mayoría se entrega al día siguiente y
  // llamarlo venta diría "ayer no vendiste" casi todos los días.
  assertStringIncludes(t, "Ayer tomaste 7 pedidos");
  assert(!t.includes("entregaste"));
  assertStringIncludes(t, "Vendido en octubre (entregado)");
  assertStringIncludes(t, "en 41 pedidos a 28 clientes");
  assertStringIncludes(t, "21 clientes atrasados");
  assertStringIncludes(t, "24 días sin comprar (compraba cada ~7)");
  // Quedan 19 que no entran en la lista: se los manda a /atrasados.
  assertStringIncludes(t, "…y 19 más: /atrasados");
  // Un cliente sin compras propias en 180 días no lleva un "$ 0/mes".
  assert(!t.includes("Kiosco_Norte: 40 días sin comprar (compraba cada ~14) —"));
});

Deno.test("formatDigestPreventista: sólo las secciones prendidas", () => {
  const soloVentas = formatDigestPreventista("2026-10-07", normalizarDatos(DATOS), ["mis_ventas"])!;
  assert(!soloVentas.includes("atrasad"));
  const soloAtrasados = formatDigestPreventista("2026-10-07", normalizarDatos(DATOS), [
    "mis_atrasados",
  ])!;
  assert(!soloAtrasados.includes("Tus ventas"));
  assertEquals(formatDigestPreventista("2026-10-07", normalizarDatos(DATOS), []), null);
});

Deno.test("formatDigestPreventista: sin atrasados lo dice, sin lista", () => {
  const d = normalizarDatos({
    ...DATOS,
    mis_atrasados: {
      clientes_en_cartera: 50,
      atrasados: 0,
      monto_mensual_en_riesgo: 0,
      clientes: [],
    },
  });
  assertStringIncludes(
    formatDigestPreventista("2026-10-07", d, ["mis_atrasados"])!,
    "Ningún cliente atrasado",
  );
});

Deno.test("formatDigestPreventista: un día sin pedidos no dice '0 pedidos por $ 0'", () => {
  const d = normalizarDatos({
    ...DATOS,
    mis_ventas: { ...DATOS.mis_ventas, dia_tomados_total: 0, dia_tomados_pedidos: 0 },
  });
  assertStringIncludes(
    formatDigestPreventista("2026-10-07", d, ["mis_ventas"])!,
    "Ayer no tomaste pedidos.",
  );
});

Deno.test("formatDigestPreventista: el 1° del mes nombra el mes anterior, no 'el mes'", () => {
  const t = formatDigestPreventista("2026-09-30", normalizarDatos(DATOS), ["mis_ventas"])!;
  assertStringIncludes(t, "Vendido en septiembre");
});

// ============================================================================
// 2. runDigestForPreventista: sin Gemini, con botones de visita
// ============================================================================

Deno.test("runDigestForPreventista: manda el resumen SIN llamar a Gemini, con un botón de visita por cliente", async () => {
  setupEnv();
  const { client, spy } = mockSupabase({
    rpc: { bot_digest_preventista: { data: DATOS, error: null } },
  });
  _setServiceRoleClientForTests(client as never);
  const f = stubFetch();
  try {
    const r = await runDigestForPreventista(client, ARGS);
    assertEquals(r.status, "ok");
    assertEquals(f.calls.filter((c) => c.url.includes("generativelanguage")).length, 0);
    const tg = f.calls.find((c) => c.url.includes("sendMessage"))!;
    assertEquals(tg.body?.chat_id, 77);
    // Texto plano: un "_" en un nombre no rompe el envío.
    assertEquals(tg.body?.parse_mode, undefined);
    const kb = tg.body?.reply_markup as {
      inline_keyboard: Array<Array<{ callback_data: string }>>;
    };
    assertEquals(kb.inline_keyboard.map((f) => f[0].callback_data), [
      "v1:visita:11",
      "v1:visita:12",
    ]);
    // La RPC recibe el perfil y la sucursal del destinatario, nada más.
    assertEquals(spy.rpcCalls[0], {
      fn: "bot_digest_preventista",
      params: { p_perfil_id: ARGS.perfil_id, p_sucursal_id: 1, p_fecha: "2026-10-07" },
    });
    assertEquals(spy.upserts.at(-1)?.row.status, "ok");
  } finally {
    f.restore();
    teardownEnv();
  }
});

Deno.test("runDigestForPreventista: sin la sección de atrasados no hay botones", async () => {
  setupEnv();
  const { client } = mockSupabase({
    rpc: { bot_digest_preventista: { data: DATOS, error: null } },
  });
  _setServiceRoleClientForTests(client as never);
  const f = stubFetch();
  try {
    await runDigestForPreventista(client, { ...ARGS, secciones: ["mis_ventas"] });
    const tg = f.calls.find((c) => c.url.includes("sendMessage"))!;
    assertEquals(tg.body?.reply_markup, undefined);
  } finally {
    f.restore();
    teardownEnv();
  }
});

Deno.test("runDigestForPreventista: si ya salió hoy no se repite", async () => {
  setupEnv();
  const { client, spy } = mockSupabase({ existente: { status: "ok" } });
  _setServiceRoleClientForTests(client as never);
  const f = stubFetch();
  try {
    const r = await runDigestForPreventista(client, ARGS);
    assertEquals(r, { status: "skipped", reason: "already_sent" });
    assertEquals(spy.rpcCalls.length, 0);
    assertEquals(f.calls.length, 0);
  } finally {
    f.restore();
    teardownEnv();
  }
});

Deno.test("runDigestForPreventista: error de la RPC → status=error con stage=datos, sin mensaje", async () => {
  setupEnv();
  const { client, spy } = mockSupabase({
    rpc: {
      bot_digest_preventista: { data: null, error: { message: "no es un preventista activo" } },
    },
  });
  _setServiceRoleClientForTests(client as never);
  const f = stubFetch();
  try {
    const r = await runDigestForPreventista(client, ARGS);
    assertEquals(r.status, "error");
    assertEquals(f.calls.length, 0);
    assertEquals(spy.upserts.at(-1)?.row.status, "error");
    assertEquals((spy.upserts.at(-1)?.row.error_meta as Record<string, unknown>).stage, "datos");
  } finally {
    f.restore();
    teardownEnv();
  }
});

Deno.test("runDigestForPreventista: falla Telegram → status=error con stage=telegram", async () => {
  setupEnv();
  const { client, spy } = mockSupabase({
    rpc: { bot_digest_preventista: { data: DATOS, error: null } },
  });
  _setServiceRoleClientForTests(client as never);
  const f = stubFetch(true);
  try {
    const r = await runDigestForPreventista(client, ARGS);
    assertEquals(r.status, "error");
    assertEquals((spy.upserts.at(-1)?.row.error_meta as Record<string, unknown>).stage, "telegram");
  } finally {
    f.restore();
    teardownEnv();
  }
});

Deno.test("runDigestForPreventista: sin sucursal no consulta nada", async () => {
  const { client, spy } = mockSupabase();
  const r = await runDigestForPreventista(client, { ...ARGS, sucursal_id: null });
  assertEquals(r.status, "skipped");
  assertEquals(spy.rpcCalls.length, 0);
});

// ============================================================================
// 3. Riesgo por preventista en el resumen del admin
// ============================================================================

const RIESGO = {
  total_atrasados: 69,
  total_monto_mensual: 3374952.64,
  sin_asignar_atrasados: 3,
  sin_asignar_monto_mensual: 223163.33,
  reservados_atrasados: 2,
  reservados_monto_mensual: 50000,
  preventistas: [
    {
      perfil_id: "a",
      nombre: "Víctor",
      atrasados: 29,
      monto_mensual_en_riesgo: 1378819,
      clientes_en_cartera: 204,
    },
    {
      perfil_id: "b",
      nombre: "Sin atrasos",
      atrasados: 0,
      monto_mensual_en_riesgo: 0,
      clientes_en_cartera: 10,
    },
  ],
};

Deno.test("formatRiesgoTexto: total, una línea por preventista con atrasados y los sin asignar", () => {
  const t = formatRiesgoTexto(RIESGO)!;
  assertStringIncludes(t, "Clientes atrasados: 69");
  assertStringIncludes(t, "• Víctor: 29 clientes");
  assertStringIncludes(t, "En ninguna cartera: 3");
  // Reservado no es "sin asignar" (mig 214): va en su propia línea.
  assertStringIncludes(t, "Reservados a administración: 2");
  // El que no tiene atrasados no ocupa una línea.
  assert(!t.includes("Sin atrasos"));
  // Las carteras se pisan: se aclara para que nadie busque la diferencia.
  assertStringIncludes(t, "cuenta en las dos carteras");
});

Deno.test("formatRiesgoTexto: sin atrasados no hay sección", () => {
  assertEquals(formatRiesgoTexto({ ...RIESGO, total_atrasados: 0, preventistas: [] }), null);
});

Deno.test("secciones: riesgo_preventistas no despierta a Gemini por sí sola", () => {
  assert(incluyeRiesgoPreventistas(["riesgo_preventistas"]));
  assert(!tieneSeccionesDeMetricas(["riesgo_preventistas"]));
  assert(!tieneSeccionesDeMetricas(["mis_ventas", "mis_atrasados"]));
});

Deno.test("runDigestForAdmin: con riesgo_preventistas pega la sección, sin modelo de por medio", async () => {
  setupEnv();
  const { client, spy } = mockSupabase({
    rpc: {
      bot_metricas_admin_dia: {
        data: { fecha: "2026-10-07", ventas_dia: { total: 1 } },
        error: null,
      },
      bot_riesgo_por_preventista: { data: RIESGO, error: null },
    },
  });
  _setServiceRoleClientForTests(client as never);
  const f = stubFetch();
  try {
    const r = await runDigestForAdmin(client, {
      telegram_user_id: 1,
      perfil_id: "33333333-3333-3333-3333-333333333333",
      sucursal_id: 1,
      fecha: "2026-10-07",
      secciones: ["ventas", "riesgo_preventistas"],
    });
    assertEquals(r.status, "ok");
    // Ninguna llamada a un modelo: ni los números del riesgo ni el resto.
    assertEquals(
      f.calls.filter((c) => /generativelanguage|api\.openai\.com/.test(c.url)).length,
      0,
    );
    const tg = f.calls.find((c) => c.url.includes("sendMessage"))!;
    assertStringIncludes(String(tg.body?.text), "Ayer no hubo pedidos.");
    assertStringIncludes(String(tg.body?.text), "• Víctor: 29 clientes");
    assertEquals(spy.rpcCalls.find((c) => c.fn === "bot_riesgo_por_preventista")?.params, {
      p_sucursal_id: 1,
    });
  } finally {
    f.restore();
    teardownEnv();
  }
});

Deno.test("runDigestForAdmin: sin riesgo_preventistas no se consulta", async () => {
  setupEnv();
  const { client, spy } = mockSupabase({
    rpc: { bot_metricas_admin_dia: { data: { fecha: "2026-10-07" }, error: null } },
  });
  _setServiceRoleClientForTests(client as never);
  const f = stubFetch();
  try {
    await runDigestForAdmin(client, {
      telegram_user_id: 1,
      perfil_id: "33333333-3333-3333-3333-333333333333",
      sucursal_id: 1,
      fecha: "2026-10-07",
      secciones: ["ventas"],
    });
    assertEquals(spy.rpcCalls.some((c) => c.fn === "bot_riesgo_por_preventista"), false);
  } finally {
    f.restore();
    teardownEnv();
  }
});

Deno.test("runDigestForAdmin: si falla el riesgo, el resumen sale igual", async () => {
  setupEnv();
  const { client } = mockSupabase({
    rpc: {
      bot_metricas_admin_dia: {
        data: { fecha: "2026-10-07", ventas_dia: { pedidos: 3, total: 9000 } },
        error: null,
      },
      bot_riesgo_por_preventista: { data: null, error: { message: "timeout" } },
    },
  });
  _setServiceRoleClientForTests(client as never);
  const f = stubFetch();
  try {
    const r = await runDigestForAdmin(client, {
      telegram_user_id: 1,
      perfil_id: "33333333-3333-3333-3333-333333333333",
      sucursal_id: 1,
      fecha: "2026-10-07",
      secciones: ["ventas", "riesgo_preventistas"],
    });
    assertEquals(r.status, "ok");
  } finally {
    f.restore();
    teardownEnv();
  }
});

// ============================================================================
// 4. El botón y lo que abre
// ============================================================================

Deno.test("buildVisitaKeyboard: callback v1:visita:<id> y el nombre en el botón", () => {
  const kb = buildVisitaKeyboard([{ cliente_id: 555, nombre: "Almacén Norte" }]);
  assertEquals(kb.inline_keyboard[0][0].callback_data, "v1:visita:555");
  assertEquals(kb.inline_keyboard[0][0].text, "🧾 Almacén Norte");
});

Deno.test("formatResumenVisita: primero lo que dejó de llevar, después lo que lleva y la plata", () => {
  const t = formatResumenVisita({
    cliente: {
      id: 11,
      codigo: 340,
      nombre: "Almacén Silvio",
      direccion: "Av. Siempreviva 742",
      telefono: null,
      es_comodin: false,
    },
    saldo: 15000,
    limite_credito: 50000,
    ritmo: {
      ultima_compra: "2026-09-13",
      dias_sin_comprar: 24,
      frecuencia_dias: 7,
      estado: "atrasado",
    },
    montos: "propios",
    top_productos: [{
      id: 1,
      nombre: "MANAOS COLA 2.25",
      pedidos_con_producto: 9,
      unidades_totales: 54,
    }],
    dejados: [{ producto_id: 2, nombre: "AZUCAR LEDESMA 1KG", ultima_vez: "2026-08-20" }],
    ultimo_pedido: {
      fecha: "2026-09-13",
      total: 42000,
      estado: "entregado",
      estado_pago: "pagado",
    },
  });
  assertStringIncludes(t, "🧾 *Almacén Silvio* \\#340");
  assert(t.indexOf("Dejó de llevar") < t.indexOf("Lo que más lleva"));
  assertStringIncludes(t, "AZUCAR LEDESMA 1KG");
  assertStringIncludes(t, "🔴 Atrasado — 24 días sin comprar, compraba cada \\~7");
  assertStringIncludes(t, "Tu último pedido");
  // MarkdownV2: los puntos de la dirección van escapados.
  assertStringIncludes(t, "Av\\. Siempreviva 742");
});

Deno.test("formatResumenVisita: un cliente ajeno muestra el rechazo, no datos", () => {
  const t = formatResumenVisita({
    cliente: null,
    saldo: null,
    limite_credito: null,
    ritmo: null,
    montos: "propios",
    top_productos: [],
    dejados: [],
    ultimo_pedido: null,
    error: "Cliente asignado a otro preventista",
  });
  assertEquals(t, "Cliente asignado a otro preventista");
});

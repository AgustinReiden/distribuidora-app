// Tests del dedup por update_id del webhook de Telegram (mig 248, #640).
//
// Telegram reintenta el webhook cuando no recibe 200 a tiempo. Lo que cubrimos:
//   1. El mismo update dos veces llega UNA sola vez al agente, y el segundo
//      pase deja un renglón tipo='duplicado' en bot_audit_log.
//   2. Un callback_query repetido tampoco se re-delega (es el caso caro:
//      "confirmar pedido" crearía el pedido dos veces).
//   3. Dos updates distintos se procesan los dos.
//   4. Si la RPC de dedup falla, se procesa igual (fail-open) y se loguea:
//      mejor un duplicado que un mensaje perdido.
//   5. El dedup no corre antes del check de secret.

import { assert, assertEquals } from "std/assert/mod.ts";
import type { SupabaseClient } from "@supabase/supabase-js";

import { handleWebhookRequest, type WebhookDeps } from "../telegram-webhook/request.ts";
import { esUpdateNuevo } from "../telegram-webhook/dedup.ts";
import { _setServiceRoleClientForTests } from "../_shared/supabase.ts";
import type { TelegramCallbackQuery, TelegramUpdate } from "../_shared/types.ts";

const SECRET = "test-webhook-secret";

interface AuditRow {
  tipo: string;
  resultado_meta?: { update_id?: number };
}

/**
 * Cliente Supabase falso que reproduce la semántica de bot_marcar_update:
 * INSERT ... ON CONFLICT DO NOTHING sobre un set en memoria, devolviendo si
 * insertó. `audit` acumula lo que se escribió en bot_audit_log.
 */
function createMockSupabase(opts: { rpcFalla?: boolean } = {}) {
  const vistos = new Set<number>();
  const audit: AuditRow[] = [];
  let rpcCalls = 0;

  const client = {
    rpc(name: string, args: Record<string, unknown>) {
      rpcCalls++;
      assertEquals(name, "bot_marcar_update");
      if (opts.rpcFalla) {
        return Promise.resolve({ data: null, error: { message: "base caida" } });
      }
      const id = args.p_update_id as number;
      const nuevo = !vistos.has(id);
      vistos.add(id);
      return Promise.resolve({ data: nuevo, error: null });
    },
    from(tabla: string) {
      assertEquals(tabla, "bot_audit_log");
      return {
        insert(row: AuditRow) {
          audit.push(row);
          return Promise.resolve({ error: null });
        },
      };
    },
  };

  return { client: client as unknown as SupabaseClient, audit, rpcCalls: () => rpcCalls };
}

/** Deps con handlers espía y el dedup REAL (pasa por la RPC mockeada). */
function createDeps() {
  const updates: TelegramUpdate[] = [];
  const callbacks: TelegramCallbackQuery[] = [];
  const deps: WebhookDeps = {
    handleUpdate: (u) => {
      updates.push(u);
      return Promise.resolve();
    },
    handleCallbackQuery: (cb) => {
      callbacks.push(cb);
      return Promise.resolve();
    },
    esUpdateNuevo,
  };
  return { deps, updates, callbacks };
}

function makeRequest(body: unknown): Request {
  return new Request("https://example.supabase.co/functions/v1/telegram-webhook", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Telegram-Bot-Api-Secret-Token": SECRET,
    },
    body: JSON.stringify(body),
  });
}

function mensaje(updateId: number): Record<string, unknown> {
  return {
    update_id: updateId,
    message: {
      message_id: 10,
      date: 1700000000,
      chat: { id: 99, type: "private" },
      from: { id: 99, is_bot: false, first_name: "Tito" },
      text: "cuanto vendio Fulano",
    },
  };
}

function callback(updateId: number): Record<string, unknown> {
  return {
    update_id: updateId,
    callback_query: {
      id: "cb-1",
      from: { id: 99, is_bot: false, first_name: "Tito" },
      message: { message_id: 10, date: 1700000000, chat: { id: 99, type: "private" } },
      data: "v1:confirmar_pedido:7",
    },
  };
}

function setup() {
  Deno.env.set("TELEGRAM_WEBHOOK_SECRET", SECRET);
}

function teardown() {
  Deno.env.delete("TELEGRAM_WEBHOOK_SECRET");
  _setServiceRoleClientForTests(null);
}

// ============================================================================
// 1. Mensaje repetido
// ============================================================================

Deno.test("el mismo update repetido llega una sola vez al agente", async () => {
  setup();
  const { client, audit } = createMockSupabase();
  _setServiceRoleClientForTests(client);
  const { deps, updates } = createDeps();

  try {
    const primera = await handleWebhookRequest(makeRequest(mensaje(555)), deps);
    const segunda = await handleWebhookRequest(makeRequest(mensaje(555)), deps);

    // Las dos responden 200: si devolviéramos 4xx/5xx Telegram reintentaría.
    assertEquals(primera.status, 200);
    assertEquals(segunda.status, 200);

    // Pero el agente lo vio una sola vez.
    assertEquals(updates.length, 1);
    assertEquals(updates[0].update_id, 555);

    // Y el reintento quedó registrado como 'duplicado'.
    const duplicados = audit.filter((r) => r.tipo === "duplicado");
    assertEquals(duplicados.length, 1);
    assertEquals(duplicados[0].resultado_meta?.update_id, 555);
  } finally {
    teardown();
  }
});

// ============================================================================
// 2. Callback repetido — el caso caro
// ============================================================================

Deno.test("un callback_query repetido no se re-delega", async () => {
  setup();
  const { client, audit } = createMockSupabase();
  _setServiceRoleClientForTests(client);
  const { deps, callbacks } = createDeps();

  try {
    await handleWebhookRequest(makeRequest(callback(777)), deps);
    await handleWebhookRequest(makeRequest(callback(777)), deps);

    assertEquals(callbacks.length, 1);
    assertEquals(callbacks[0].data, "v1:confirmar_pedido:7");
    assertEquals(audit.filter((r) => r.tipo === "duplicado").length, 1);
  } finally {
    teardown();
  }
});

// ============================================================================
// 3. Updates distintos
// ============================================================================

Deno.test("dos updates distintos se procesan los dos", async () => {
  setup();
  const { client, audit } = createMockSupabase();
  _setServiceRoleClientForTests(client);
  const { deps, updates } = createDeps();

  try {
    await handleWebhookRequest(makeRequest(mensaje(1)), deps);
    await handleWebhookRequest(makeRequest(mensaje(2)), deps);

    assertEquals(updates.map((u) => u.update_id), [1, 2]);
    assertEquals(audit.filter((r) => r.tipo === "duplicado").length, 0);
  } finally {
    teardown();
  }
});

// ============================================================================
// 4. Fail-open: si la RPC falla, se procesa igual
// ============================================================================

Deno.test("si bot_marcar_update falla, el update se procesa igual", async () => {
  setup();
  const { client } = createMockSupabase({ rpcFalla: true });
  _setServiceRoleClientForTests(client);
  const { deps, updates } = createDeps();

  try {
    const res = await handleWebhookRequest(makeRequest(mensaje(9)), deps);
    assertEquals(res.status, 200);
    // Mejor un duplicado que un mensaje perdido.
    assertEquals(updates.length, 1);
  } finally {
    teardown();
  }
});

// ============================================================================
// 5. El dedup no corre antes del check de secret
// ============================================================================

Deno.test("un request sin el secret se rechaza sin tocar la base", async () => {
  setup();
  const { client, rpcCalls } = createMockSupabase();
  _setServiceRoleClientForTests(client);
  const { deps, updates } = createDeps();

  try {
    const req = new Request("https://example.supabase.co/functions/v1/telegram-webhook", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(mensaje(3)),
    });
    const res = await handleWebhookRequest(req, deps);

    assertEquals(res.status, 403);
    assertEquals(rpcCalls(), 0);
    assert(updates.length === 0);
  } finally {
    teardown();
  }
});

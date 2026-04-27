// Edge Function: telegram-digest
//
// Disparada por pg_cron (configurado en migration 018) a las 10:00 UTC todos
// los días, equivalente a 07:00 ART. Para cada admin vinculado al bot:
//   * calcula métricas del día anterior (RPC bot_metricas_admin_dia),
//   * pide a Gemini una narrativa ejecutiva,
//   * envía el mensaje por Telegram,
//   * registra el envío en bot_digests_enviados (idempotencia + auditoría).
//
// Una invocación HTTP a esta función dispara una run para todos los admins.
// Cada admin se procesa con Promise.allSettled para que el fallo de uno no
// pinche al resto. La idempotencia está garantizada por la PK
// (admin_perfil_id, fecha) en bot_digests_enviados — un retry del cron en
// el mismo día NO duplica mensajes.
//
// Auth: bearer token == SUPABASE_SERVICE_ROLE_KEY. Como el cron pasa esa
// key en `Authorization`, no podemos basarnos en `verify_jwt = false` solo;
// validamos manualmente. Cualquier otro caller (incluyendo el frontend)
// debe usar la misma key — equivalente a "endpoint admin-only invocable
// solo desde el server".
//
// Variables de entorno:
//   - SUPABASE_URL                  (auto-inyectada)
//   - SUPABASE_SERVICE_ROLE_KEY     (auto-inyectada, también validada como bearer)
//   - GEMINI_API_KEY                (secret)
//   - GEMINI_MODEL                  (opcional; default gemini-2.5-flash)
//   - TELEGRAM_BOT_TOKEN            (secret)

import { serve } from "std/http/server.ts";
import { getServiceRoleClient } from "../_shared/supabase.ts";
import { runDigestForAdmin } from "./digest.ts";

interface AdminRow {
  telegram_user_id: number;
  perfil_id: string;
  sucursal_id: number | null;
}

serve(async (req: Request) => {
  // 1. Auth: bearer == SUPABASE_SERVICE_ROLE_KEY. Fail-closed si no está
  //    configurado (mismo patrón que telegram-webhook con su SECRET).
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!serviceKey) {
    console.error("[digest] SUPABASE_SERVICE_ROLE_KEY not set");
    return new Response("forbidden", { status: 403 });
  }

  const auth = req.headers.get("Authorization") ?? "";
  if (auth !== `Bearer ${serviceKey}`) {
    return new Response("forbidden", { status: 403 });
  }

  // 2. Resolver fecha del digest: ayer en TZ Argentina.
  const fecha = ayerEnArgentina();

  // 3. Cargar admins activos vinculados al bot.
  const sb = getServiceRoleClient();
  const { data: admins, error } = await sb
    .from("bot_usuarios")
    .select("telegram_user_id, perfil_id, sucursal_id, rol, activo")
    .eq("rol", "admin")
    .eq("activo", true);

  if (error) {
    console.error("[digest] error fetching admins:", error.message);
    return jsonResponse({ ok: false, error: error.message }, 500);
  }

  if (!admins || admins.length === 0) {
    return jsonResponse({ ok: true, fecha, skipped: true, reason: "no admins" });
  }

  // 4. Procesar cada admin con allSettled — fallo de uno no rompe al resto.
  const tasks = admins.map((a) => {
    const row = a as Record<string, unknown>;
    const admin: AdminRow = {
      telegram_user_id: Number(row.telegram_user_id),
      perfil_id: String(row.perfil_id),
      sucursal_id: row.sucursal_id == null ? null : Number(row.sucursal_id),
    };
    return runDigestForAdmin(sb, { ...admin, fecha });
  });

  const results = await Promise.allSettled(tasks);

  const summary = results.map((r, i) => {
    const row = admins[i] as Record<string, unknown>;
    const base = {
      admin_perfil_id: String(row.perfil_id),
      telegram_user_id: Number(row.telegram_user_id),
    };
    if (r.status === "fulfilled") {
      return { ...base, status: r.value.status, reason: r.value.reason };
    }
    return {
      ...base,
      status: "error" as const,
      reason: r.reason instanceof Error ? r.reason.message : String(r.reason),
    };
  });

  return jsonResponse({ ok: true, fecha, results: summary });
});

function ayerEnArgentina(): string {
  // YYYY-MM-DD para "ayer" en TZ ART. Usamos Intl.DateTimeFormat con timeZone
  // para que el resultado sea robusto frente a la TZ del runtime de Supabase
  // (que es UTC, pero queremos el "ayer" del punto de vista de un argentino).
  const ahora = new Date();
  const ayer = new Date(ahora.getTime() - 24 * 60 * 60 * 1000);
  const fmt = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  return fmt.format(ayer);
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

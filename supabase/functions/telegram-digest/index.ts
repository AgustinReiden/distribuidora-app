// Edge Function: telegram-digest
//
// Disparada por .github/workflows/telegram-digest.yml CADA HORA en punto (+
// workflow_dispatch). Corre seguido porque el horario es por persona: cada
// admin elige a qué hora y qué días quiere su resumen (`bot_digest_config`), y
// en cada corrida la RPC `bot_digest_destinatarios` contesta a quién le toca
// en esta hora. Antes era un solo disparo diario a las 07:00 para todos.
// La migración 018 programaba el disparo con
// pg_cron + pg_net, pero esas extensiones nunca estuvieron habilitadas en
// prod y el digest no corrió ni una vez (#661) — ver el comentario de
// cabecera de esa migración. Para cada admin vinculado al bot:
//   * calcula métricas del día anterior (RPC bot_metricas_admin_dia),
//   * pide a Gemini una narrativa ejecutiva,
//   * si su sucursal tiene lotes en vencimiento crítico, le suma una sección
//     al final del mismo mensaje (#565, ver digest.ts y vencimientos.ts),
//   * envía el mensaje por Telegram,
//   * registra el envío en bot_digests_enviados (idempotencia + auditoría).
//
// Además, para encargado y depósito (que no reciben el digest de ventas):
// un mensaje propio y aparte, solo el listado de lotes críticos, una vez por
// (perfil, sucursal) por día — idempotencia en bot_avisos_vencimiento_enviados,
// ver vencimientos.ts. Si no hay lotes críticos no se les manda nada.
//
// Una invocación HTTP a esta función dispara una run para todos los admins y
// para todos los encargado/depósito. Cada uno se procesa con
// Promise.allSettled para que el fallo de uno no pinche al resto.
//
// Auth: header `X-Digest-Key` == secret TELEGRAM_DIGEST_KEY. NO usamos
// SUPABASE_SERVICE_ROLE_KEY para esto (se probó y se descartó, #661): ese
// nombre está reservado por la plataforma — Supabase no deja setearlo a mano
// como function secret ("Name must not start with the SUPABASE_ prefix"), y
// depender del auto-injection dejó el endpoint devolviendo 403 sin forma de
// diagnosticar cuál de las dos ramas (falta la key vs. no matchea) estaba
// fallando. Un secret propio, cargado a mano, es verificable de punta a
// punta. Cualquier otro caller (incluyendo el frontend) debe mandar el mismo
// header — equivalente a "endpoint admin-only invocable solo desde el server".
//
// Variables de entorno:
//   - SUPABASE_URL                  (auto-inyectada)
//   - SUPABASE_SERVICE_ROLE_KEY     (auto-inyectada; usada para el client de datos, NO para auth del trigger)
//   - TELEGRAM_DIGEST_KEY           (secret; valida el header X-Digest-Key)
//   - GEMINI_API_KEY                (secret)
//   - GEMINI_MODEL                  (opcional; default gemini-2.5-flash)
//   - TELEGRAM_BOT_TOKEN            (secret)

import { serve } from "std/http/server.ts";
import { getServiceRoleClient } from "../_shared/supabase.ts";
import { timingSafeEqual } from "../_shared/telegram.ts";
import { runDigestForAdmin } from "./digest.ts";
import { runAvisosVencimiento } from "./vencimientos.ts";

interface AdminRow {
  telegram_user_id: number;
  perfil_id: string;
  sucursal_id: number | null;
  /** Secciones elegidas por esta persona. Ver telegram-digest/secciones.ts. */
  secciones: string[];
}

serve(async (req: Request) => {
  // 1. Auth: header X-Digest-Key == secret TELEGRAM_DIGEST_KEY. Fail-closed
  //    si no está configurado (mismo patrón que telegram-webhook con su
  //    SECRET).
  const digestKey = Deno.env.get("TELEGRAM_DIGEST_KEY") ?? "";
  if (!digestKey) {
    console.error("[digest] TELEGRAM_DIGEST_KEY not set");
    return new Response("forbidden", { status: 403 });
  }

  const headerKey = req.headers.get("X-Digest-Key") ?? "";
  // Comparación en tiempo constante (consistencia con telegram-webhook; evita
  // timing attacks al validar el secret). P2-6 de la auditoría 2026-05.
  if (!timingSafeEqual(headerKey, digestKey)) {
    return new Response("forbidden", { status: 403 });
  }

  // 2. Resolver fecha del digest: ayer en TZ Argentina.
  const fecha = ayerEnArgentina();

  // 3. A quién le toca el digest en ESTA hora.
  //
  // La decisión vive en `bot_digest_destinatarios` (SQL) y no acá: cruza
  // `bot_usuarios` con `bot_digest_config` y aplica hora, días y secciones en
  // un solo lugar verificable. El admin sin fila de config recibe el default,
  // que es el digest de siempre — por eso no hubo backfill.
  //
  // La hora y el día se calculan acá, en TZ Argentina, porque este módulo ya
  // es el dueño de esa conversión (ver `ayerEnArgentina`). La RPC los recibe
  // como parámetros y queda pura: se la puede probar con cualquier hora.
  const sb = getServiceRoleClient();
  const hora = horaEnArgentina();
  const dow = diaIsoEnArgentina();

  const { data: destinatarios, error } = await sb.rpc(
    "bot_digest_destinatarios",
    { p_hora: hora, p_dow: dow },
  );

  if (error) {
    console.error("[digest] error resolviendo destinatarios:", error.message);
    return jsonResponse({ ok: false, error: error.message }, 500);
  }

  const admins = (destinatarios ?? []) as Array<Record<string, unknown>>;

  if (admins.length === 0) {
    return jsonResponse({
      ok: true,
      fecha,
      hora,
      dow,
      skipped: true,
      reason: "nadie configurado para esta hora",
    });
  }

  const tasks = admins.map((row) => {
    const admin: AdminRow = {
      telegram_user_id: Number(row.telegram_user_id),
      perfil_id: String(row.perfil_id),
      sucursal_id: row.sucursal_id == null ? null : Number(row.sucursal_id),
      secciones: Array.isArray(row.secciones) ? row.secciones.map(String) : [],
    };
    return runDigestForAdmin(sb, { ...admin, fecha });
  });

  const results = await Promise.allSettled(tasks);

  const summary = results.map((r, i) => {
    const row = admins[i];
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

  // 5. Avisos de vencimiento crítico para encargado/depósito (#565). Mensaje
  //    propio, sin Gemini, uno por (perfil, sucursal) por día — idempotencia
  //    en bot_avisos_vencimiento_enviados, no en bot_digests_enviados (esa PK
  //    es (admin_perfil_id, fecha) y descartaría el segundo aviso de un
  //    encargado con dos sucursales).
  //    Fecha HOY, no "ayer": a diferencia del digest de ventas (que resume
  //    el día anterior), `bot_reporte_vencimientos` calcula contra el
  //    calendario del momento en que corre — es el estado de los lotes hoy,
  //    no un cierre de un día pasado.
  const hoy = hoyEnArgentina();
  const avisosVencimiento = await runAvisosVencimiento(sb, hoy);

  return jsonResponse({
    ok: true,
    fecha,
    hora,
    dow,
    results: summary,
    avisos_vencimiento: avisosVencimiento,
  });
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

/**
 * Hora (0..23) en TZ Argentina. `hour12: false` da "24" a medianoche en vez de
 * "00" en algunos runtimes, asi que el 24 se normaliza a 0 — si no, nadie con
 * `hora_local = 0` recibiria nunca su digest.
 */
function horaEnArgentina(): number {
  const fmt = new Intl.DateTimeFormat("en-GB", {
    timeZone: "America/Argentina/Buenos_Aires",
    hour: "2-digit",
    hour12: false,
  });
  const h = Number(fmt.format(new Date()));
  return h % 24;
}

/**
 * Dia de la semana ISO en TZ Argentina: 1 = lunes … 7 = domingo. Coincide con
 * `EXTRACT(ISODOW)` de Postgres, que es contra lo que se guarda `dias_semana`.
 */
function diaIsoEnArgentina(): number {
  const fmt = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Argentina/Buenos_Aires",
    weekday: "short",
  });
  const dias: Record<string, number> = {
    Mon: 1,
    Tue: 2,
    Wed: 3,
    Thu: 4,
    Fri: 5,
    Sat: 6,
    Sun: 7,
  };
  return dias[fmt.format(new Date())] ?? 1;
}

/** YYYY-MM-DD para "hoy" en TZ ART. Ver `ayerEnArgentina` para el porqué de `Intl.DateTimeFormat`. */
function hoyEnArgentina(): string {
  const fmt = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  return fmt.format(new Date());
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

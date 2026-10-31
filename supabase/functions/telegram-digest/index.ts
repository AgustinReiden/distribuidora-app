// Edge Function: telegram-digest
//
// Disparada por .github/workflows/telegram-digest.yml CADA HORA en punto (+
// workflow_dispatch). Corre seguido porque el horario es por persona: cada
// admin elige a qué hora y qué días quiere su resumen (`bot_digest_config`), y
// en cada corrida la RPC `bot_digest_pendientes` contesta a quién le toca y
// todavía no lo recibió: desde su hora EN ADELANTE, no sólo dentro de ella
// (#1309). El cron horario de GitHub llega tarde o se saltea horas, y con la
// hora exacta un día sin corrida entre las 7 y las 7:59 se perdía entero.
// Antes era un solo disparo diario a las 07:00 para todos.
//
// Un resumen por cada sucursal asignada al admin (#1309), con su nombre en el
// encabezado: no la de /sucursal, que es la que mira en el chat.
// La migración 018 programaba el disparo con
// pg_cron + pg_net, pero esas extensiones nunca estuvieron habilitadas en
// prod y el digest no corrió ni una vez (#661) — ver el comentario de
// cabecera de esa migración. Para cada admin vinculado al bot:
// (Desde la mig 311 también preventistas que lo pidieron: ven lo que vendieron
// y sus clientes atrasados, armado sin modelo — ver preventista.ts.)
//   * calcula métricas del día anterior (RPC bot_metricas_admin_dia),
//   * lo arma con plantilla, sin modelo (admin.ts, #1041),
//   * si su sucursal tiene lotes en vencimiento crítico, le suma una sección
//     al final del mismo mensaje (#565, ver digest.ts y vencimientos.ts),
//   * toma la marca en bot_digests_enviados ANTES de mandar (marca.ts): de
//     dos corridas a la vez, una sola manda,
//   * envía el mensaje por Telegram y cierra la marca (auditoría).
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
//   - TELEGRAM_BOT_TOKEN            (secret)

import { serve } from "std/http/server.ts";
import { getServiceRoleClient } from "../_shared/supabase.ts";
import { timingSafeEqual } from "../_shared/telegram.ts";
import { runDigestForAdmin } from "./digest.ts";
import { runDigestForPreventista } from "./preventista.ts";
import { runAvisosVencimiento } from "./vencimientos.ts";
import { runAvisosAtrasados } from "./atrasados.ts";
import { relojDigest } from "./reloj.ts";

interface AdminRow {
  telegram_user_id: number;
  perfil_id: string;
  /** 'admin' o 'preventista' (mig 311). Decide qué resumen se arma. */
  rol: string;
  /** La sucursal resumida: una fila por cada sucursal asignada (#1309). */
  sucursal_id: number | null;
  sucursal_nombre: string | null;
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

  // 2. La fecha del digest (ayer), la de hoy, la hora y el día, en TZ
  //    Argentina y desde el mismo instante (reloj.ts).
  const { fecha, hoy, hora, dow } = relojDigest();

  // 3. A quién le toca el digest y todavía no lo recibió.
  //
  // La decisión vive en `bot_digest_pendientes` (SQL) y no acá: cruza
  // `bot_usuarios` con `bot_digest_config` y las sucursales asignadas, y aplica
  // hora, días, secciones y "ya enviado" en un solo lugar verificable (la misma
  // definición que mira el gate, `auditoria_bot`). El admin sin fila de config
  // recibe el default, que es el digest de siempre.
  //
  // La hora, el día y la fecha resumida se calculan en TS (reloj.ts), dueño de
  // la conversión a TZ Argentina. La RPC los recibe como parámetros: se la
  // puede probar con cualquier hora.
  const sb = getServiceRoleClient();

  const { data: destinatarios, error } = await sb.rpc(
    "bot_digest_pendientes",
    { p_fecha: fecha, p_hora: hora, p_dow: dow },
  );

  if (error) {
    console.error("[digest] error resolviendo destinatarios:", error.message);
    return jsonResponse({ ok: false, error: error.message }, 500);
  }

  const admins = (destinatarios ?? []) as Array<Record<string, unknown>>;

  if (admins.length === 0) {
    // El aviso de atrasados tiene su propio horario (por defecto lunes 8:00,
    // cuando los admins ya recibieron el suyo a las 7): corre aunque no haya
    // ningún resumen pendiente. Los avisos de vencimiento siguen atados a la
    // corrida que manda los resúmenes, como antes (y son idempotentes por día).
    const avisosAtrasados = await runAvisosAtrasados(sb, hora, dow, hoy);
    return jsonResponse({
      ok: true,
      fecha,
      hora,
      dow,
      skipped: true,
      reason: "ningún resumen pendiente",
      avisos_atrasados: avisosAtrasados,
    });
  }

  const tasks = admins.map((row) => {
    const admin: AdminRow = {
      telegram_user_id: Number(row.telegram_user_id),
      perfil_id: String(row.perfil_id),
      // Sin `rol` (una RPC anterior a la 311) es el admin de siempre.
      rol: row.rol == null ? "admin" : String(row.rol),
      sucursal_id: row.sucursal_id == null ? null : Number(row.sucursal_id),
      sucursal_nombre: row.sucursal_nombre == null ? null : String(row.sucursal_nombre),
      secciones: Array.isArray(row.secciones) ? row.secciones.map(String) : [],
    };
    // El preventista recibe su resumen sin modelo (preventista.ts); el admin,
    // el de siempre. Cualquier otro rol no debería venir de la RPC: se ignora.
    if (admin.rol === "preventista") {
      return runDigestForPreventista(sb, { ...admin, fecha });
    }
    if (admin.rol !== "admin") {
      return Promise.resolve({ status: "skipped" as const, reason: `rol ${admin.rol}` });
    }
    const { rol: _rol, ...datosAdmin } = admin;
    return runDigestForAdmin(sb, { ...datosAdmin, fecha });
  });

  const results = await Promise.allSettled(tasks);

  const summary = results.map((r, i) => {
    const row = admins[i];
    const base = {
      admin_perfil_id: String(row.perfil_id),
      sucursal_id: row.sucursal_id == null ? null : Number(row.sucursal_id),
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
  const avisosVencimiento = await runAvisosVencimiento(sb, hoy);

  // 6. Aviso semanal de clientes atrasados para preventistas (mig 325): sin
  //    modelo, por defecto los lunes a las 8; cada uno con su día y hora.
  const avisosAtrasados = await runAvisosAtrasados(sb, hora, dow, hoy);

  return jsonResponse({
    ok: true,
    fecha,
    hora,
    dow,
    results: summary,
    avisos_vencimiento: avisosVencimiento,
    avisos_atrasados: avisosAtrasados,
  });
});

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

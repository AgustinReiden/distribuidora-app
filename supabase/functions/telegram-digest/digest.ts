// Lógica del digest ejecutivo diario por admin.
//
// Para cada admin vinculado el flujo es:
//   1. Verificar idempotencia: si ya hay row 'ok' en bot_digests_enviados
//      para (admin_perfil_id, fecha) → skip.
//   2. Llamar RPC bot_metricas_admin_dia(p_fecha, p_sucursal_id) → JSON.
//   3. Cargar el system prompt `digest_admin.txt` (cacheado en memoria).
//   4. Llamar Gemini con el JSON serializado en un user message → texto narrativo.
//   5. Enviar el mensaje a Telegram (plain text, sin Markdown — el LLM puede
//      emitir formato dudoso y no queremos que la falla de parseo descarte
//      el digest entero).
//   6. UPSERT en bot_digests_enviados con status='ok'/'error' y error_meta
//      con `stage` para distinguir si falló la RPC, Gemini o Telegram.
//   7. Audit log (best-effort) en bot_audit_log.
//
// Cualquier error en el flujo se persiste en bot_digests_enviados con
// status='error' y un objeto error_meta con `{stage, error}` para post-mortem.
// El error NO se propaga al caller — runDigestForAdmin retorna un DigestResult
// para que el index.ts pueda hacer el resumen sin que un admin con problema
// pinche al resto.

import type { SupabaseClient } from "@supabase/supabase-js";
import { callGemini } from "../_shared/gemini/client.ts";
import { sendMessage } from "../_shared/telegram.ts";
import { logEvent } from "../_shared/audit.ts";
import { isTextPart } from "../_shared/gemini/types.ts";
import digestAdminPrompt from "../_shared/gemini/prompts/digest_admin.ts";

export interface DigestArgs {
  telegram_user_id: number;
  perfil_id: string;
  sucursal_id: number | null;
  /** YYYY-MM-DD — fecha del día a resumir (típicamente "ayer" en ART). */
  fecha: string;
}

export interface DigestResult {
  status: "ok" | "skipped" | "error";
  reason?: string;
}

// Override de tests (null = usar el módulo importado estáticamente). Mantiene
// el patrón de los seams previos: nombres y semántica intactos para no romper
// los tests existentes.
let _digestPromptOverride: string | null = null;

function getDigestPrompt(): string {
  return _digestPromptOverride ?? digestAdminPrompt;
}

/** Test seam: limpia el override del prompt entre tests. */
export function _clearDigestPromptCacheForTests(): void {
  _digestPromptOverride = null;
}

/** Test seam: setea el prompt sin tocar el módulo. */
export function _setDigestPromptForTests(text: string): void {
  _digestPromptOverride = text;
}

/**
 * Ejecuta el digest para un admin: idempotencia + RPC + Gemini + Telegram +
 * registro en bot_digests_enviados. Nunca lanza — retorna DigestResult.
 */
export async function runDigestForAdmin(
  sb: SupabaseClient,
  args: DigestArgs,
): Promise<DigestResult> {
  const { telegram_user_id, perfil_id, sucursal_id, fecha } = args;

  // 0. Idempotencia: si ya se envió 'ok' hoy, skip. Si la fila existe pero
  //    es 'error', dejamos pasar para reintentar (UPSERT al final).
  const { data: existente } = await sb
    .from("bot_digests_enviados")
    .select("status")
    .eq("admin_perfil_id", perfil_id)
    .eq("fecha", fecha)
    .maybeSingle();

  const existenteStatus = (existente as { status?: string } | null)?.status;
  if (existenteStatus === "ok") {
    return { status: "skipped", reason: "already_sent" };
  }

  // 1. Métricas via RPC.
  const { data: metricas, error: errMetricas } = await sb.rpc(
    "bot_metricas_admin_dia",
    { p_fecha: fecha, p_sucursal_id: sucursal_id },
  );

  if (errMetricas) {
    await registrarEnvio(sb, perfil_id, fecha, telegram_user_id, "error", {
      stage: "metricas",
      error: errMetricas.message,
    });
    return { status: "error", reason: errMetricas.message };
  }

  // 2. Prompt + 3. Gemini.
  let texto: string;
  try {
    const systemPrompt = getDigestPrompt();
    const userMessage = `Métricas del ${fecha} (sucursal ${sucursal_id ?? "todas"}):\n\n${
      JSON.stringify(metricas, null, 2)
    }`;

    const response = await callGemini({
      system_instruction: { parts: [{ text: systemPrompt }] },
      contents: [{ role: "user", parts: [{ text: userMessage }] }],
      generationConfig: { temperature: 0.3, maxOutputTokens: 1024 },
    });

    const part = response.candidates?.[0]?.content?.parts?.[0];
    texto = part && isTextPart(part) ? part.text.trim() : "";
    if (!texto) {
      throw new Error("Gemini returned empty text");
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    await registrarEnvio(sb, perfil_id, fecha, telegram_user_id, "error", {
      stage: "gemini",
      error: msg,
    });
    return { status: "error", reason: msg };
  }

  // 4. Telegram (plain text, sin parse_mode).
  // Header con emoji + fecha legible ("lun 27/04/2026" en vez de
  // "2026-04-27"), después divider, después el texto del LLM.
  const mensaje = `🌅 Resumen ${formatFechaLegible(fecha)}\n` +
    `━━━━━━━━━━━━━━\n\n${texto}`;
  try {
    await sendMessage(telegram_user_id, mensaje);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    await registrarEnvio(sb, perfil_id, fecha, telegram_user_id, "error", {
      stage: "telegram",
      error: msg,
    });
    return { status: "error", reason: msg };
  }

  // 5. Registrar OK.
  await registrarEnvio(sb, perfil_id, fecha, telegram_user_id, "ok");

  // 6. Audit log (best-effort: si falla no rompemos el digest).
  try {
    await logEvent({
      telegram_user_id,
      perfil_id,
      rol: "admin",
      tipo: "respuesta",
      texto_bot: texto,
      resultado_meta: { digest: true, fecha, sucursal_id },
    });
  } catch (auditErr) {
    console.error(
      "[digest] audit log failed (non-fatal):",
      auditErr instanceof Error ? auditErr.message : String(auditErr),
    );
  }

  return { status: "ok" };
}

async function registrarEnvio(
  sb: SupabaseClient,
  admin_perfil_id: string,
  fecha: string,
  telegram_user_id: number,
  status: "ok" | "error" | "skipped",
  error_meta?: Record<string, unknown>,
): Promise<void> {
  const { error } = await sb.from("bot_digests_enviados").upsert(
    {
      admin_perfil_id,
      fecha,
      sent_at: new Date().toISOString(),
      telegram_user_id,
      status,
      error_meta: error_meta ?? null,
    },
    { onConflict: "admin_perfil_id,fecha" },
  );
  if (error) {
    // No lanzamos: el digest puede haber salido OK aunque el registro falle.
    // Lo dejamos en consola para que sea visible en los logs de la function.
    console.error(
      `[digest] bot_digests_enviados upsert failed (perfil_id=${admin_perfil_id}, fecha=${fecha}, status=${status}):`,
      error.message,
    );
  }
}

/**
 * Formatea YYYY-MM-DD como "lun 27/04/2026" para el header del digest.
 * Si la fecha no parsea, devuelve la string original (defensivo: nunca
 * queremos que un fallo de Date parsing dropee el mensaje entero).
 *
 * Usamos `Intl.DateTimeFormat` con timeZone explícita ART para evitar que
 * el runtime del Edge interprete YYYY-MM-DD como UTC y devuelva el día
 * anterior en zonas con offset negativo.
 */
function formatFechaLegible(fecha: string): string {
  // Construimos la fecha como UTC mediodía para sortear bordes de TZ —
  // el día calendario es el mismo en cualquier TZ razonable.
  const d = new Date(`${fecha}T12:00:00Z`);
  if (Number.isNaN(d.getTime())) return fecha;
  const fmt = new Intl.DateTimeFormat("es-AR", {
    weekday: "short",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    timeZone: "America/Argentina/Buenos_Aires",
  });
  // Salida: "lun., 27/04/2026" — limpiamos el punto del weekday corto y la
  // coma para que quede "lun 27/04/2026".
  return fmt.format(d).replace(/\./g, "").replace(",", "");
}

// Edge Function: telegram-webhook
//
// Endpoint que Telegram llama vía setWebhook. Responsabilidades:
//  1. Aceptar solo POST (Telegram nunca usa otros métodos).
//  2. Validar el secret que configuramos al hacer setWebhook
//     (header X-Telegram-Bot-Api-Secret-Token, comparado en constant-time).
//  3. Parsear el JSON del Update y delegar al handler.
//  4. Loguear errores en bot_audit_log para post-mortem.
//  5. SIEMPRE responder 200 OK al final del flujo "happy" (después del
//     check de auth), porque si devolvemos 4xx/5xx Telegram reintenta y
//     se desordena el procesamiento de updates. Errores internos se logean
//     pero igual respondemos 200.
//
// Variables de entorno requeridas (set en Supabase Dashboard):
//   - SUPABASE_URL                  (auto-inyectada por Supabase)
//   - SUPABASE_SERVICE_ROLE_KEY     (auto-inyectada por Supabase)
//   - TELEGRAM_BOT_TOKEN            (BotFather)
//   - TELEGRAM_WEBHOOK_SECRET       (string random, único por proyecto)

import { serve } from "std/http/server.ts";
import { logEvent } from "../_shared/audit.ts";
import { parseUpdate, timingSafeEqual } from "../_shared/telegram.ts";
import { handleUpdate } from "./handlers.ts";

serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405 });
  }

  // ---------- 1) Validar secret ---------------------------------------
  const expected = Deno.env.get("TELEGRAM_WEBHOOK_SECRET");
  if (!expected) {
    // Fail-closed: si el secret no está configurado, rechazamos todo.
    console.error("TELEGRAM_WEBHOOK_SECRET not set");
    return new Response("forbidden", { status: 403 });
  }

  // Telegram manda el secret SOLO en el header `X-Telegram-Bot-Api-Secret-Token`
  // cuando configuramos `setWebhook` con `secret_token`. No aceptamos query
  // param: queda en logs/history/error reports y es un anti-pattern para
  // material secreto.
  const headerSecret = req.headers.get("X-Telegram-Bot-Api-Secret-Token") ?? "";
  if (!timingSafeEqual(headerSecret, expected)) {
    return new Response("forbidden", { status: 403 });
  }

  // ---------- 2) Parsear body -----------------------------------------
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return new Response("bad request", { status: 400 });
  }

  const update = parseUpdate(body);

  // Updates sin message+text+from no nos interesan en Fase 1.2 (callbacks,
  // ediciones, etc. los ignoramos). Igual respondemos 200 para que Telegram
  // no reintente — pero auditamos para mantener el contrato "todo update
  // recibido queda registrado".
  if (!update?.message?.text || !update.message.from) {
    try {
      await logEvent({
        telegram_user_id: update?.message?.from?.id,
        tipo: "mensaje",
        texto_usuario: null,
        resultado_meta: {
          reason: "unsupported_update_shape",
          raw_keys: body && typeof body === "object"
            ? Object.keys(body as Record<string, unknown>)
            : [],
        },
      });
    } catch (auditErr) {
      // Best-effort: no queremos que un fallo de audit haga reintentar a
      // Telegram. Logueamos a consola y seguimos.
      console.error("telegram-webhook audit dropped-update failed", auditErr);
    }
    return new Response("ok");
  }

  // ---------- 3) Handler con catch defensivo --------------------------
  try {
    await handleUpdate(update);
  } catch (err) {
    console.error("telegram-webhook handler error", err);
    // Best-effort audit del error. Si esto también falla, ya logeamos a
    // la consola arriba.
    try {
      await logEvent({
        telegram_user_id: update.message.from.id,
        tipo: "error",
        texto_usuario: update.message.text,
        resultado_meta: { error: err instanceof Error ? err.message : String(err) },
      });
    } catch (auditErr) {
      console.error("telegram-webhook audit-of-error failed", auditErr);
    }
  }

  return new Response("ok");
});

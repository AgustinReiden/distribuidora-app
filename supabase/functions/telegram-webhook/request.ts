// Handler HTTP del webhook de Telegram.
//
// Vive separado de index.ts —que sólo hace `serve(handleWebhookRequest)`—
// para que los tests puedan ejercitar el flujo entero sin levantar un
// servidor, e inyectar handlers falsos.
//
// Responsabilidades:
//  1. Aceptar solo POST (Telegram nunca usa otros métodos).
//  2. Validar el secret que configuramos al hacer setWebhook
//     (header X-Telegram-Bot-Api-Secret-Token, comparado en constant-time).
//  3. Descartar los reintentos de Telegram por update_id (mig 248).
//  4. Parsear el JSON del Update y delegar al handler.
//  5. Loguear errores en bot_audit_log para post-mortem.
//  6. SIEMPRE responder 200 OK al final del flujo "happy" (después del
//     check de auth), porque si devolvemos 4xx/5xx Telegram reintenta y
//     se desordena el procesamiento de updates. Errores internos se logean
//     pero igual respondemos 200.

import { logEvent } from "../_shared/audit.ts";
import { parseUpdate, timingSafeEqual } from "../_shared/telegram.ts";
import type { TelegramCallbackQuery, TelegramUpdate } from "../_shared/types.ts";
import { handleCallbackQuery, handleUpdate } from "./handlers.ts";
import { esUpdateNuevo } from "./dedup.ts";

/**
 * Colaboradores del handler. Existen para que el test pueda observar si el
 * update llegó (o no) al agente; en producción se usan los defaults.
 */
export interface WebhookDeps {
  handleUpdate: (update: TelegramUpdate) => Promise<void>;
  handleCallbackQuery: (cb: TelegramCallbackQuery) => Promise<void>;
  esUpdateNuevo: (updateId: number) => Promise<boolean>;
}

const DEFAULT_DEPS: WebhookDeps = { handleUpdate, handleCallbackQuery, esUpdateNuevo };

export async function handleWebhookRequest(
  req: Request,
  deps: WebhookDeps = DEFAULT_DEPS,
): Promise<Response> {
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

  // ---------- 3) Dedup por update_id ----------------------------------
  // Va ANTES de delegar: el reintento de Telegram trae el mismo update_id y
  // reprocesarlo duplica pedidos. Sólo aplica si el payload traía un
  // update_id parseable; si no, no hay nada por qué dedupear y cae en la
  // rama de "shape no soportado" más abajo.
  if (update && !(await deps.esUpdateNuevo(update.update_id))) {
    try {
      await logEvent({
        telegram_user_id: update.message?.from?.id ?? update.callback_query?.from.id,
        tipo: "duplicado",
        texto_usuario: update.message?.text ?? null,
        resultado_meta: {
          update_id: update.update_id,
          reason: "reintento_de_telegram",
        },
      });
    } catch (auditErr) {
      console.error("telegram-webhook audit duplicado failed", auditErr);
    }
    return new Response("ok");
  }

  // Discriminamos por shape:
  //   - callback_query: usuario tocó un inline keyboard.
  //   - message con text+from: slash command o NL.
  //   - cualquier otro shape (edited_message, channel_post, sin texto, etc.)
  //     se ignora — auditamos para visibilidad.
  if (update?.callback_query) {
    try {
      await deps.handleCallbackQuery(update.callback_query);
    } catch (err) {
      console.error("telegram-webhook callback handler error", err);
      try {
        await logEvent({
          telegram_user_id: update.callback_query.from.id,
          tipo: "error",
          resultado_meta: {
            error: err instanceof Error ? err.message : String(err),
            source: "callback_query",
          },
        });
      } catch (auditErr) {
        console.error("telegram-webhook audit-of-callback-error failed", auditErr);
      }
    }
    return new Response("ok");
  }

  // El handleUpdate acepta message con text, voice o audio. Cualquier otro
  // shape (edited_message, channel_post, sticker, etc.) lo descartamos
  // como unsupported.
  const msg = update?.message;
  const hasContent = !!(msg?.text || msg?.voice || msg?.audio);
  if (!msg || !hasContent || !msg.from) {
    try {
      await logEvent({
        telegram_user_id: msg?.from?.id,
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
      console.error("telegram-webhook audit dropped-update failed", auditErr);
    }
    return new Response("ok");
  }

  // ---------- 4) Handler con catch defensivo --------------------------
  try {
    await deps.handleUpdate(update);
  } catch (err) {
    console.error("telegram-webhook handler error", err);
    try {
      await logEvent({
        telegram_user_id: msg.from!.id,
        tipo: "error",
        texto_usuario: msg.text ?? null,
        resultado_meta: { error: err instanceof Error ? err.message : String(err) },
      });
    } catch (auditErr) {
      console.error("telegram-webhook audit-of-error failed", auditErr);
    }
  }

  return new Response("ok");
}

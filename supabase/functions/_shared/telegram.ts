// Helpers para hablar con la Bot API de Telegram. Solo lo mínimo necesario
// para Task 1.2 (sendMessage + parser de updates + escapeMarkdownV2).
// Referencia: https://core.telegram.org/bots/api

import type { TelegramUpdate, TelegramUser } from "./types.ts";

const TELEGRAM_API_BASE = "https://api.telegram.org";

export interface SendMessageOptions {
  parse_mode?: "MarkdownV2" | "HTML";
  disable_web_page_preview?: boolean;
  reply_to_message_id?: number;
}

export interface SendMessageResult {
  ok: boolean;
  result?: unknown;
  description?: string;
  error_code?: number;
}

/**
 * POST a sendMessage. Lee TELEGRAM_BOT_TOKEN del env. Lanza si la API
 * responde con `ok: false` o si la red falla — el caller decide qué hacer.
 */
export async function sendMessage(
  chatId: number,
  text: string,
  opts: SendMessageOptions = {},
): Promise<SendMessageResult> {
  const token = Deno.env.get("TELEGRAM_BOT_TOKEN");
  if (!token) {
    throw new Error("TELEGRAM_BOT_TOKEN not set in Edge Function environment");
  }

  const url = `${TELEGRAM_API_BASE}/bot${token}/sendMessage`;
  const body: Record<string, unknown> = {
    chat_id: chatId,
    text,
    ...opts,
  };

  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  let payload: SendMessageResult;
  try {
    payload = (await res.json()) as SendMessageResult;
  } catch {
    throw new Error(`Telegram sendMessage returned non-JSON (status ${res.status})`);
  }

  if (!res.ok || !payload.ok) {
    throw new Error(
      `Telegram sendMessage failed (status ${res.status}, code ${payload.error_code}): ${
        payload.description ?? "<no description>"
      }`,
    );
  }

  return payload;
}

/**
 * Escapa los caracteres especiales de MarkdownV2 según la spec de Telegram.
 * Reservados: _ * [ ] ( ) ~ ` > # + - = | { } . ! y backslash.
 * https://core.telegram.org/bots/api#markdownv2-style
 */
export function escapeMarkdownV2(text: string): string {
  return text.replace(/([\\_*\[\]()~`>#+\-=|{}.!])/g, "\\$1");
}

/**
 * Detecta si un error de `sendMessage` es un fallo de parseo de MarkdownV2 —
 * típicamente "Bad Request: can't parse entities" cuando el texto tiene
 * escapes mal aplicados. Solo en ese caso queremos caer al fallback plain
 * text: errores de red, chat_id inválido, rate limits, etc. NO deben
 * mutarse silenciosamente a un mensaje sin formato.
 */
function isMarkdownParseError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  // Telegram devuelve "Bad Request: can't parse entities: ..." con varias
  // sub-causas; basta con detectar el prefijo "can't parse" (case-insensitive)
  // o el genérico "parse entities". El status también es útil pero el
  // sendMessage actual no lo expone — usamos el mensaje.
  return /can'?t parse|parse entities/i.test(msg);
}

/**
 * Envía mensaje con `parse_mode: MarkdownV2`. Si Telegram rechaza el formato
 * (escapes mal aplicados → 400 "can't parse entities"), reintenta como plain
 * text para que el usuario reciba algo legible en vez de nada. Esto es
 * defense-in-depth: si un formatter tiene un bug de escape, el comando
 * todavía responde. NO silencia errores de red u otros 4xx/5xx — solo el
 * fallo de parseo de markdown. Si el segundo intento (plain) también falla,
 * el error se propaga al caller.
 */
export async function sendMessageMarkdownSafe(
  chatId: number,
  markdownV2Text: string,
): Promise<void> {
  try {
    await sendMessage(chatId, markdownV2Text, { parse_mode: "MarkdownV2" });
    return;
  } catch (err) {
    if (!isMarkdownParseError(err)) {
      // Network / rate-limit / chat invalid / etc — propagar.
      throw err;
    }
    console.warn(
      "[telegram] MarkdownV2 parse rejected, falling back to plain text:",
      err instanceof Error ? err.message : String(err),
    );
  }
  // Despojamos de la sintaxis MarkdownV2 más obvia para que se lea.
  // 1) Unescape de los chars MarkdownV2 (`\\.` → `.`).
  // 2) Strip de markers `*` `_` `` ` ``  (bold/italic/mono).
  const plain = markdownV2Text
    .replace(/\\([_*\[\]()~`>#+\-=|{}.!])/g, "$1")
    .replace(/[*_`]/g, "");
  await sendMessage(chatId, plain);
}

/**
 * Comparación de strings constant-time para evitar timing attacks al validar
 * secrets/tokens. NO usar `===` para comparar el `X-Telegram-Bot-Api-Secret-Token`
 * porque la duración del `===` filtra cuántos chars iniciales matchearon.
 *
 * Implementación XOR sobre charCodes: O(min(a.length, b.length)) tiempo,
 * sin early-return cuando hay diff. El short-circuit por longitud diferente
 * es aceptable (la longitud del secret no es secreta una vez fijada).
 */
export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

/**
 * Type guard mínimo: verifica que `body` tenga la forma de un Update válido
 * (al menos `update_id: number`). Retorna null si no parsea — el caller
 * responde 200 OK igualmente para no causar reintento de Telegram.
 */
export function parseUpdate(body: unknown): TelegramUpdate | null {
  if (!body || typeof body !== "object") return null;
  const candidate = body as Record<string, unknown>;

  if (typeof candidate.update_id !== "number") return null;

  const update: TelegramUpdate = { update_id: candidate.update_id };

  if (candidate.message && typeof candidate.message === "object") {
    const msg = candidate.message as Record<string, unknown>;
    if (
      typeof msg.message_id === "number" &&
      typeof msg.date === "number" &&
      msg.chat && typeof msg.chat === "object"
    ) {
      const chat = msg.chat as Record<string, unknown>;
      if (
        typeof chat.id === "number" && typeof chat.type === "string" &&
        (chat.type === "private" || chat.type === "group" ||
          chat.type === "supergroup" || chat.type === "channel")
      ) {
        update.message = {
          message_id: msg.message_id,
          date: msg.date,
          chat: { id: chat.id, type: chat.type },
          text: typeof msg.text === "string" ? msg.text : undefined,
          from: parseFromUser(msg.from),
        };
      }
    }
  }

  return update;
}

function parseFromUser(raw: unknown): TelegramUser | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const u = raw as Record<string, unknown>;
  if (
    typeof u.id !== "number" || typeof u.is_bot !== "boolean" ||
    typeof u.first_name !== "string"
  ) {
    return undefined;
  }
  const out: TelegramUser = {
    id: u.id,
    is_bot: u.is_bot,
    first_name: u.first_name,
  };
  if (typeof u.last_name === "string") out.last_name = u.last_name;
  if (typeof u.username === "string") out.username = u.username;
  if (typeof u.language_code === "string") out.language_code = u.language_code;
  return out;
}

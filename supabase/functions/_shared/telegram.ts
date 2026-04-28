// Helpers para hablar con la Bot API de Telegram.
// Referencia: https://core.telegram.org/bots/api

import type {
  TelegramCallbackQuery,
  TelegramMessage,
  TelegramUpdate,
  TelegramUser,
  TelegramVoice,
} from "./types.ts";

const TELEGRAM_API_BASE = "https://api.telegram.org";

// ----------------------------------------------------------------------------
// Tipos compartidos: keyboards, mensajes, chat actions
// ----------------------------------------------------------------------------

/**
 * Botón de inline keyboard. La Bot API permite varios tipos de botones — acá
 * solo modelamos los dos que usa el bot: callback (genera un callback_query)
 * y url (abre link externo). Los demás (`switch_inline_query`, `pay`, etc.)
 * se pueden agregar cuando aparezca un caso de uso real.
 *
 * Restricción de Telegram: `callback_data` ≤ 64 bytes UTF-8. El bot usa el
 * formato `v1:<action>:<arg1>[:<arg2>...]` — los keyboard builders truncan
 * texto largo pero el callback_data en sí debe ser corto por diseño.
 */
export interface InlineKeyboardButton {
  text: string;
  callback_data?: string;
  url?: string;
}

export interface InlineKeyboardMarkup {
  /** Filas de botones. Cada fila es un array horizontal. */
  inline_keyboard: InlineKeyboardButton[][];
}

export interface SendMessageOptions {
  parse_mode?: "MarkdownV2" | "HTML";
  disable_web_page_preview?: boolean;
  reply_to_message_id?: number;
  /** Inline keyboard que aparece debajo del mensaje. */
  reply_markup?: InlineKeyboardMarkup;
}

export interface SendMessageResult {
  ok: boolean;
  result?: unknown;
  description?: string;
  error_code?: number;
}

/**
 * Acciones que el bot puede mostrar al usuario para indicar "estoy
 * trabajando". Telegram las muestra ~5s y se autodescartan. Las que usa el
 * bot son básicamente `typing` (mientras LLM procesa). El resto está acá por
 * compatibilidad con la spec.
 * https://core.telegram.org/bots/api#sendchataction
 */
export type ChatAction =
  | "typing"
  | "upload_photo"
  | "record_video"
  | "upload_video"
  | "record_voice"
  | "upload_voice"
  | "upload_document"
  | "choose_sticker"
  | "find_location"
  | "record_video_note"
  | "upload_video_note";

export interface AnswerCallbackQueryOptions {
  /** Texto opcional que aparece como notification (≤ 200 chars). */
  text?: string;
  /** Si true, modal en vez de notification. Útil para errores claros. */
  show_alert?: boolean;
  /** Cache del client para evitar repreguntar (segundos). Default 0. */
  cache_time?: number;
}

// ----------------------------------------------------------------------------
// Helper interno: invocación cruda de Bot API
// ----------------------------------------------------------------------------

/**
 * POST genérico al endpoint `/bot{token}/{method}` de Telegram. Lanza con un
 * Error descriptivo si la red falla o si la API devuelve `ok: false`. Cada
 * helper público decide si propagar el error o capturarlo (best-effort).
 */
async function callTelegramApi<T = unknown>(
  method: string,
  body: Record<string, unknown>,
): Promise<{ ok: true; result?: T }> {
  const token = Deno.env.get("TELEGRAM_BOT_TOKEN");
  if (!token) {
    throw new Error("TELEGRAM_BOT_TOKEN not set in Edge Function environment");
  }

  const url = `${TELEGRAM_API_BASE}/bot${token}/${method}`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  let payload: {
    ok?: boolean;
    result?: T;
    description?: string;
    error_code?: number;
  };
  try {
    payload = await res.json();
  } catch {
    throw new Error(
      `Telegram ${method} returned non-JSON (status ${res.status})`,
    );
  }

  if (!res.ok || !payload.ok) {
    throw new Error(
      `Telegram ${method} failed (status ${res.status}, code ${payload.error_code}): ${
        payload.description ?? "<no description>"
      }`,
    );
  }

  return { ok: true, result: payload.result };
}

// ----------------------------------------------------------------------------
// API pública
// ----------------------------------------------------------------------------

/**
 * POST a sendMessage. Lee TELEGRAM_BOT_TOKEN del env. Lanza si la API
 * responde con `ok: false` o si la red falla — el caller decide qué hacer.
 */
export async function sendMessage(
  chatId: number,
  text: string,
  opts: SendMessageOptions = {},
): Promise<SendMessageResult> {
  const body: Record<string, unknown> = {
    chat_id: chatId,
    text,
    ...opts,
  };
  const r = await callTelegramApi("sendMessage", body);
  return { ok: true, result: r.result };
}

/**
 * Indica al usuario que el bot está procesando ("typing…"). Telegram muestra
 * el indicador ~5s y se autodescarta — si el LLM tarda más, no loopeamos.
 *
 * Best-effort: errores se loguean y se descartan. NO queremos que un fallo
 * en sendChatAction aborte el flujo principal del handler.
 */
export async function sendChatAction(
  chatId: number,
  action: ChatAction,
): Promise<void> {
  try {
    await callTelegramApi("sendChatAction", { chat_id: chatId, action });
  } catch (err) {
    console.warn(
      "[telegram] sendChatAction failed (non-fatal):",
      err instanceof Error ? err.message : String(err),
    );
  }
}

/**
 * Resuelve el `file_path` de un file_id (necesario antes de descargar).
 * https://core.telegram.org/bots/api#getfile
 *
 * Errores propagan: si fallás bajando el archivo, no hay nada que
 * transcribir y el caller necesita saberlo.
 */
export async function getFile(
  file_id: string,
): Promise<{ file_path: string; file_size?: number }> {
  const r = await callTelegramApi<{ file_path: string; file_size?: number }>(
    "getFile",
    { file_id },
  );
  if (!r.result?.file_path) {
    throw new Error(`getFile returned no file_path for file_id=${file_id}`);
  }
  return { file_path: r.result.file_path, file_size: r.result.file_size };
}

/**
 * Descarga el binary del archivo. La URL es distinta de la API JSON: el
 * endpoint de archivos es `/file/bot{token}/{file_path}` (sin /bot{token}/
 * como prefijo de método).
 *
 * Errores propagan.
 */
export async function downloadTelegramFile(file_path: string): Promise<Uint8Array> {
  const token = Deno.env.get("TELEGRAM_BOT_TOKEN");
  if (!token) {
    throw new Error("TELEGRAM_BOT_TOKEN not set in Edge Function environment");
  }
  const url = `${TELEGRAM_API_BASE}/file/bot${token}/${file_path}`;
  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(
      `downloadTelegramFile failed (status ${res.status}): ${
        await res.text().catch(() => "<no body>")
      }`,
    );
  }
  return new Uint8Array(await res.arrayBuffer());
}

/**
 * Confirma la recepción de un callback_query. Sin esta llamada, el botón en
 * la UI del cliente Telegram queda con un spinner por hasta 30s. Llamala
 * SIEMPRE al final de handleCallbackQuery, aunque haya habido error — con
 * un texto distinto en cada caso.
 *
 * Best-effort: errores se loguean. Si esto falla, el usuario ve el spinner
 * más tiempo, pero el resto del flujo (mensaje nuevo, audit log) ya pasó.
 */
export async function answerCallbackQuery(
  callbackQueryId: string,
  opts: AnswerCallbackQueryOptions = {},
): Promise<void> {
  const body: Record<string, unknown> = {
    callback_query_id: callbackQueryId,
    ...opts,
  };
  try {
    await callTelegramApi("answerCallbackQuery", body);
  } catch (err) {
    console.warn(
      "[telegram] answerCallbackQuery failed (non-fatal):",
      err instanceof Error ? err.message : String(err),
    );
  }
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
  opts: Omit<SendMessageOptions, "parse_mode"> = {},
): Promise<void> {
  try {
    await sendMessage(chatId, markdownV2Text, {
      ...opts,
      parse_mode: "MarkdownV2",
    });
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
  // El reply_markup (si vino) se preserva intacto — no es markdown.
  const plain = markdownV2Text
    .replace(/\\([_*\[\]()~`>#+\-=|{}.!])/g, "$1")
    .replace(/[*_`]/g, "");
  await sendMessage(chatId, plain, opts);
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
 *
 * Acepta dos shapes principales:
 *   - `message`: mensaje de texto (slash command o NL).
 *   - `callback_query`: usuario tocó un inline keyboard.
 *
 * Otros shapes (edited_message, channel_post, etc.) se ignoran — el caller
 * los detecta por la ausencia de ambos campos y los loguea como
 * `unsupported_update_shape`.
 */
export function parseUpdate(body: unknown): TelegramUpdate | null {
  if (!body || typeof body !== "object") return null;
  const candidate = body as Record<string, unknown>;

  if (typeof candidate.update_id !== "number") return null;

  const update: TelegramUpdate = { update_id: candidate.update_id };

  const parsedMessage = parseMessage(candidate.message);
  if (parsedMessage) update.message = parsedMessage;

  const parsedCallback = parseCallbackQuery(candidate.callback_query);
  if (parsedCallback) update.callback_query = parsedCallback;

  return update;
}

function parseMessage(raw: unknown): TelegramMessage | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const msg = raw as Record<string, unknown>;
  if (
    typeof msg.message_id !== "number" ||
    typeof msg.date !== "number" ||
    !msg.chat || typeof msg.chat !== "object"
  ) {
    return undefined;
  }
  const chat = msg.chat as Record<string, unknown>;
  if (
    typeof chat.id !== "number" || typeof chat.type !== "string" ||
    (chat.type !== "private" && chat.type !== "group" &&
      chat.type !== "supergroup" && chat.type !== "channel")
  ) {
    return undefined;
  }
  return {
    message_id: msg.message_id,
    date: msg.date,
    chat: { id: chat.id, type: chat.type },
    text: typeof msg.text === "string" ? msg.text : undefined,
    from: parseFromUser(msg.from),
    voice: parseVoiceLike(msg.voice),
    audio: parseVoiceLike(msg.audio),
  };
}

function parseVoiceLike(raw: unknown): TelegramVoice | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const v = raw as Record<string, unknown>;
  if (typeof v.file_id !== "string" || typeof v.file_unique_id !== "string") {
    return undefined;
  }
  if (typeof v.duration !== "number") return undefined;
  return {
    file_id: v.file_id,
    file_unique_id: v.file_unique_id,
    duration: v.duration,
    mime_type: typeof v.mime_type === "string" ? v.mime_type : undefined,
    file_size: typeof v.file_size === "number" ? v.file_size : undefined,
  };
}

function parseCallbackQuery(raw: unknown): TelegramCallbackQuery | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const cb = raw as Record<string, unknown>;
  // id, from, message son requeridos para un callback útil. data es opcional
  // (puede venir vacío si el botón usaba `url`, aunque ese caso no genera
  // callback_query — más bien defense-in-depth).
  if (typeof cb.id !== "string") return undefined;
  const from = parseFromUser(cb.from);
  if (!from) return undefined;
  const message = parseMessage(cb.message);
  if (!message) return undefined;

  return {
    id: cb.id,
    from,
    message,
    data: typeof cb.data === "string" ? cb.data : undefined,
    chat_instance: typeof cb.chat_instance === "string"
      ? cb.chat_instance
      : undefined,
  };
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

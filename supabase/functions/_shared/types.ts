// Tipos compartidos del bot de Telegram. Definimos solo lo que usamos del
// objeto Update de la Bot API para evitar arrastrar @types externos —
// referencia: https://core.telegram.org/bots/api#update

export interface TelegramUser {
  id: number;
  is_bot: boolean;
  first_name: string;
  last_name?: string;
  username?: string;
  language_code?: string;
}

export interface TelegramChat {
  id: number;
  type: "private" | "group" | "supergroup" | "channel";
}

/**
 * Voice o audio adjunto en un Telegram message. La spec:
 *   https://core.telegram.org/bots/api#voice
 *   https://core.telegram.org/bots/api#audio
 *
 * Tratamos `voice` y `audio` con el mismo shape — ambos vienen como Ogg
 * Opus desde la app móvil de Telegram. La diferencia conceptual (voice =
 * grabación in-app, audio = archivo de música subido) no afecta la
 * transcripción.
 */
export interface TelegramVoice {
  file_id: string;
  file_unique_id: string;
  /** Duración en segundos. Útil para validar antes de descargar. */
  duration: number;
  /** Típicamente "audio/ogg" para voice, "audio/mpeg" para audio files. */
  mime_type?: string;
  /** Bytes. Telegram permite hasta 20 MB para voice messages. */
  file_size?: number;
}

export interface TelegramMessage {
  message_id: number;
  date: number;
  chat: TelegramChat;
  from?: TelegramUser;
  text?: string;
  /** Voice message (grabado en la app de Telegram). Hoy lo usamos para
   *  transcripción → texto → flow normal del LLM. */
  voice?: TelegramVoice;
  /** Audio file (subido desde el celular o un archivo). Mismo flujo que
   *  voice — los tratamos juntos. */
  audio?: TelegramVoice;
}

/**
 * Update generado cuando el usuario toca un botón de inline keyboard.
 * Telegram entrega `data` (el callback_data del botón, ≤ 64 bytes) y el
 * mensaje al que pertenecía el keyboard. El bot debe responder con
 * `answerCallbackQuery` para apagar el spinner del cliente.
 * https://core.telegram.org/bots/api#callbackquery
 */
export interface TelegramCallbackQuery {
  id: string;
  from: TelegramUser;
  /** Mensaje original que tenía el inline keyboard. */
  message: TelegramMessage;
  /** Payload del botón (callback_data). Vacío si el botón usaba `url`. */
  data?: string;
  /** Hash que Telegram usa para deduplicar — informativo, no lo validamos. */
  chat_instance?: string;
}

export interface TelegramUpdate {
  update_id: number;
  message?: TelegramMessage;
  callback_query?: TelegramCallbackQuery;
}

// ----------------------------------------------------------------------------
// Tipos del dominio del bot (reflejan tablas en migrations/014_bot_telegram.sql).
// ----------------------------------------------------------------------------

export type BotRol = "admin" | "preventista" | "transportista" | "deposito" | "encargado";

export interface BotUser {
  telegram_user_id: number;
  perfil_id: string;
  /** Rol principal (`perfiles.rol`): elige el system prompt. */
  rol: BotRol;
  /**
   * Todos los roles en la sucursal activa: el principal más los extra de
   * `perfil_roles` (mig 296). El bot le da la unión de herramientas. Sin esto
   * un preventista que además reparte no ve las herramientas de transportista.
   * Ausente = sólo `rol` (fixtures viejos de tests).
   */
  roles?: BotRol[];
  sucursal_id: number | null;
  activo: boolean;
}

export const BOT_ROLES: ReadonlyArray<BotRol> = [
  "admin",
  "encargado",
  "preventista",
  "transportista",
  "deposito",
];

/** Los roles del usuario, con el principal siempre incluido. */
export function rolesDe(u: { rol: BotRol; roles?: ReadonlyArray<BotRol> }): BotRol[] {
  const set = new Set<BotRol>([u.rol, ...(u.roles ?? [])]);
  return BOT_ROLES.filter((r) => set.has(r));
}

export type BotAuditTipo =
  | "mensaje"
  | "tool_call"
  | "respuesta"
  | "error"
  | "comando"
  /** Reintento de Telegram descartado por el dedup de update_id (mig 248). */
  | "duplicado";

export interface CanjearCodigoOk {
  ok: true;
  user: BotUser & { nombre: string };
}

export interface CanjearCodigoFail {
  ok: false;
  error:
    | "no_encontrado"
    | "expirado"
    | "ya_usado"
    | "perfil_invalido"
    /** Lockout del canje: 5 fallos en 15 minutos (mig 237). */
    | "bloqueado"
    | "rpc_error";
  /** Solo viene con `bloqueado`: cuánto falta para poder reintentar. */
  segundos_restantes?: number;
}

export type CanjearCodigoResult = CanjearCodigoOk | CanjearCodigoFail;

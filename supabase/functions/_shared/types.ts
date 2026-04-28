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

export interface TelegramMessage {
  message_id: number;
  date: number;
  chat: TelegramChat;
  from?: TelegramUser;
  text?: string;
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
  rol: BotRol;
  sucursal_id: number | null;
  activo: boolean;
}

export type BotAuditTipo = "mensaje" | "tool_call" | "respuesta" | "error" | "comando";

export interface CanjearCodigoOk {
  ok: true;
  user: BotUser & { nombre: string };
}

export interface CanjearCodigoFail {
  ok: false;
  error: "no_encontrado" | "expirado" | "ya_usado" | "perfil_invalido" | "rpc_error";
}

export type CanjearCodigoResult = CanjearCodigoOk | CanjearCodigoFail;

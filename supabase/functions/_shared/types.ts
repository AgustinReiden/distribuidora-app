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

export interface TelegramUpdate {
  update_id: number;
  message?: TelegramMessage;
}

// ----------------------------------------------------------------------------
// Tipos del dominio del bot (reflejan tablas en migrations/014_bot_telegram.sql).
// ----------------------------------------------------------------------------

export type BotRol = "admin" | "preventista" | "transportista";

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

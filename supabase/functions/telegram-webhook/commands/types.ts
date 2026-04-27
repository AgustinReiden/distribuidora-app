// Tipos compartidos del command router del bot.
//
// Diseño:
//   * Cada CommandSpec se registra en commands/router.ts. El router los
//     resuelve por nombre (case-insensitive) y delega al handler con un
//     CommandContext ya armado (user resuelto, toolCtx listo, args parseados).
//   * El scope decide quién puede invocar el comando:
//       - "guest": usuarios no vinculados también (poco común — solo /start, /vincular, /ayuda).
//       - "any": cualquier rol vinculado.
//       - BotRol[]: solo esos roles vinculados.
//   * El CommandContext.toolCtx es null cuando el user no está vinculado
//     (porque no podemos invocar tools sin perfil_id/rol/sucursal). Los
//     handlers de scope!="guest" pueden asumir que toolCtx no es null si
//     el router validó scope correctamente — igual los handlers individuales
//     hacen un guard defensivo.

import type { ToolContext } from "../../_shared/tools/base.ts";
import type { BotRol, BotUser, TelegramUser } from "../../_shared/types.ts";

export interface CommandContext {
  /** El BotUser ya resuelto (vinculado). null si no está vinculado. */
  user: BotUser | null;
  /** El user de Telegram (para audit + first_name fallback). */
  tgUser: TelegramUser;
  /** El chat_id donde responder. */
  chatId: number;
  /** Los args luego del comando (string crudo, sin trim). */
  rawArgs: string;
  /** ToolContext listo para invocar tools. null si user es null. */
  toolCtx: ToolContext | null;
}

export interface CommandSpec {
  /** Nombre canónico, con barra inicial y minúsculas: "/cliente". */
  name: string;
  /** Aliases opcionales (también con barra inicial). */
  aliases?: string[];
  /** Texto humano para /ayuda. */
  description: string;
  /**
   * Quién puede invocar el comando:
   *  - "guest": cualquiera, vinculado o no.
   *  - "any": cualquier rol vinculado.
   *  - ReadonlyArray<BotRol>: solo esos roles vinculados.
   */
  scope: "guest" | "any" | ReadonlyArray<BotRol>;
  /** Handler async. El router captura excepciones y audita el error. */
  handler: (ctx: CommandContext) => Promise<void>;
}

// Parser de comandos del bot.
//
// Telegram permite que un comando lleve sufijo `@bot_name` cuando el bot está
// en un grupo (ej: `/start@distri_bot`). El parser deja eso fuera para que
// el router compare contra `/start` directamente.
//
// El `rawArgs` se devuelve SIN trim — los handlers que necesiten texto crudo
// (ej: `/cliente Pepito San Martín`) ven el prefijo de espacios original; los
// que necesiten un valor limpio harán `rawArgs.trim()` ellos mismos.

export interface ParsedCommand {
  /** Nombre del comando con barra y en minúsculas: "/cliente". */
  command: string;
  /** Resto del texto luego del comando (sin trim). */
  rawArgs: string;
}

const COMMAND_RE = /^\/([A-Za-z0-9_]+)(?:@[A-Za-z0-9_]+)?(?:\s+([\s\S]*))?$/;

/**
 * Parsea `/<nombre>(@<bot>)?( <args>)?` y devuelve nombre normalizado + args
 * crudos. Retorna null si el texto no parece un comando (no empieza con `/`,
 * o el nombre tiene chars inválidos).
 */
export function parseCommand(text: string): ParsedCommand | null {
  const trimmed = text.trim();
  if (!trimmed.startsWith("/")) return null;

  const m = trimmed.match(COMMAND_RE);
  if (!m) return null;

  return {
    command: "/" + m[1].toLowerCase(),
    rawArgs: m[2] ?? "",
  };
}

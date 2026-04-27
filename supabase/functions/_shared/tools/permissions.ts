// Filtrado de tools por rol. Trivial por ahora — un day 1 puede crecer si
// agregamos permisos más finos (ej: "puede invocar pero solo sus propios
// recursos"). Hoy alcanza con allowedRoles.includes(rol).

import type { Tool } from "./base.ts";
import type { BotRol } from "../types.ts";

export function canInvoke(rol: BotRol, tool: Tool): boolean {
  return tool.allowedRoles.includes(rol);
}

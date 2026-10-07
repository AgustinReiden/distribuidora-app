// Filtrado de tools por rol.
//
// Un usuario puede tener más de un rol (mig 296: el principal más los extra de
// `perfil_roles` en su sucursal activa). Recibe la unión de herramientas, pero
// cada herramienta corre con UN rol: el de más alcance entre los suyos que la
// herramienta acepta. Ese rol es el que la RPC recibe como `p_rol` y el que
// decide qué datos ve (un preventista que además reparte usa `historico` como
// preventista y `mi_recorrido_hoy` como transportista).

import type { Tool } from "./base.ts";
import { BOT_ROLES, type BotRol } from "../types.ts";

function comoLista(roles: BotRol | ReadonlyArray<BotRol>): ReadonlyArray<BotRol> {
  return typeof roles === "string" ? [roles] : roles;
}

/**
 * El rol con el que corre la tool para este usuario, o null si ninguno de sus
 * roles la habilita. El orden de BOT_ROLES va de más a menos alcance.
 */
export function rolEfectivo(
  roles: BotRol | ReadonlyArray<BotRol>,
  tool: Tool,
): BotRol | null {
  const propios = comoLista(roles);
  return BOT_ROLES.find((r) => propios.includes(r) && tool.allowedRoles.includes(r)) ?? null;
}

export function canInvoke(roles: BotRol | ReadonlyArray<BotRol>, tool: Tool): boolean {
  return rolEfectivo(roles, tool) !== null;
}

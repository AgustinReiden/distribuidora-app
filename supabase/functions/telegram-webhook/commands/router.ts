// Router de comandos del bot. Map global comando→spec.
//
// Diseño: registro central explícito (en lugar de auto-registro al importar
// cada comando). Más controlable y testeable — los tests pueden llamar
// `clearCommandsForTests()` y re-registrar a voluntad.
//
// Cada alias se registra en el mismo Map apuntando al MISMO spec, así
// `getCommand("/buscarcliente")` retorna el spec de `/cliente` sin lookup
// adicional. `listCommands()` deduplica vía Set para que /ayuda no muestre
// duplicados.

import type { CommandSpec } from "./types.ts";

const COMMANDS = new Map<string, CommandSpec>();

/**
 * Registra un command spec. Lanza si el nombre o un alias ya existe — esto
 * previene shadowing accidental si alguien duplica un import en el boot.
 */
export function registerCommand(spec: CommandSpec): void {
  if (COMMANDS.has(spec.name)) {
    throw new Error(`Comando ya registrado: ${spec.name}`);
  }
  COMMANDS.set(spec.name, spec);
  for (const alias of spec.aliases ?? []) {
    if (COMMANDS.has(alias)) {
      throw new Error(`Alias ya registrado: ${alias}`);
    }
    COMMANDS.set(alias, spec);
  }
}

/** Lookup case-sensitive por nombre/alias (con barra inicial). */
export function getCommand(name: string): CommandSpec | undefined {
  return COMMANDS.get(name);
}

/** Lista de specs únicos (deduplicada por aliases). */
export function listCommands(): CommandSpec[] {
  return [...new Set(COMMANDS.values())];
}

/** Test helper: limpia el registro. NO usar desde producción. */
export function clearCommandsForTests(): void {
  COMMANDS.clear();
}

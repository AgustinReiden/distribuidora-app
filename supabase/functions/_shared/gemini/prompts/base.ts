// Carga de system prompts por rol.
//
// Los prompts se embeben como módulos TS (uno por rol) y se importan
// estáticamente. Razón: en el deploy de Supabase Edge Functions el bundler
// solo incluye archivos TS/JS, así que un Deno.readTextFile sobre un .txt
// resuelto via import.meta.url falla con "path not found" en producción.
// Los .ts viajan en el bundle siempre — esto es portable, type-safe y
// elimina permisos de --allow-read en runtime.
//
// API pública (`getSystemPrompt`, `setSystemPromptForTests`,
// `clearSystemPromptCache`) se mantiene compatible con los call sites previos
// para no romper tests ni callers.

import type { BotRol } from "../../types.ts";
import adminPrompt from "./admin.ts";
import preventistaPrompt from "./preventista.ts";
import transportistaPrompt from "./transportista.ts";
import encargadoPrompt from "./encargado.ts";
import depositoPrompt from "./deposito.ts";

const DEFAULTS: Record<BotRol, string> = {
  admin: adminPrompt,
  preventista: preventistaPrompt,
  transportista: transportistaPrompt,
  encargado: encargadoPrompt,
  deposito: depositoPrompt,
};

// Overrides aplicables solo desde tests via setSystemPromptForTests.
const OVERRIDES = new Map<BotRol, string>();

/**
 * Carga el system prompt para el rol del usuario. Async por compat con la
 * implementación previa basada en FS — el contenido viene de un módulo
 * importado estáticamente, no se va al disco.
 */
// deno-lint-ignore require-await
export async function getSystemPrompt(rol: BotRol): Promise<string> {
  const override = OVERRIDES.get(rol);
  if (override !== undefined) return override;
  return DEFAULTS[rol];
}

// ----------------------------------------------------------------------------
// Test seams
// ----------------------------------------------------------------------------

/** Override del prompt en memoria. Útil para tests sin tocar el FS. */
export function setSystemPromptForTests(rol: BotRol, text: string): void {
  OVERRIDES.set(rol, text);
}

/**
 * Limpia los overrides de tests. El nombre se mantiene por compat con los
 * tests existentes — ya no hay un "cache" propiamente dicho, los defaults
 * son constantes inmutables del módulo.
 */
export function clearSystemPromptCache(): void {
  OVERRIDES.clear();
}

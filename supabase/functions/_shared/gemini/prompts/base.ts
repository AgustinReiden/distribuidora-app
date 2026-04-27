// Carga de system prompts por rol.
//
// Los prompts viven como archivos .txt al lado de este módulo. Razón: son
// texto largo, los queremos editar sin tocar código TS, y mantenerlos fuera
// del bundle hace los diffs más legibles. En Deno los .txt no se importan
// como módulos, así que los leemos con `Deno.readTextFile` resolviendo
// `import.meta.url`. Los prompts pesan pocos KB, los cacheamos en memoria
// tras la primera lectura.
//
// El cache es per-isolate. En edge functions el isolate persiste warm entre
// invocations del mismo deploy, así que los prompts se leen del FS solo en el
// primer cold start. Reset manual disponible para tests via
// `clearSystemPromptCache`.

import type { BotRol } from "../../types.ts";

const PROMPTS = new Map<BotRol, string>();

async function loadPromptOnce(rol: BotRol): Promise<string> {
  const cached = PROMPTS.get(rol);
  if (cached !== undefined) return cached;
  const url = new URL(`./${rol}.txt`, import.meta.url);
  const text = await Deno.readTextFile(url);
  PROMPTS.set(rol, text);
  return text;
}

/**
 * Carga el system prompt para el rol del usuario.
 * Cachea en memoria — los prompts son estáticos.
 */
export async function getSystemPrompt(rol: BotRol): Promise<string> {
  return await loadPromptOnce(rol);
}

// ----------------------------------------------------------------------------
// Test seams
// ----------------------------------------------------------------------------

/** Override del prompt en memoria. Útil para tests sin tocar el FS. */
export function setSystemPromptForTests(rol: BotRol, text: string): void {
  PROMPTS.set(rol, text);
}

/** Limpia el cache. Llamar entre tests para evitar bleed. */
export function clearSystemPromptCache(): void {
  PROMPTS.clear();
}

// Mapper Tool (registry interno) → GeminiFunctionDeclaration.
//
// Los schemas de las tools en `_shared/tools/**` ya están escritos en JSON
// Schema subset compatible con OpenAPI 3.0 — que es lo que Gemini acepta para
// `function_declarations.parameters`. Por eso este mapper es trivial: solo
// extrae name/description/parameters.
//
// Caveats (a tener presente cuando agreguemos tools nuevas):
//   - Gemini IGNORA $ref, oneOf/anyOf/allOf, patternProperties, formats raros
//     (uuid, etc). Si una tool agrega esos, sanitizá acá antes de pasar.
//   - description es OBLIGATORIA en Gemini. Si la tool no la trae, throw.
//   - Gemini soporta "type", "description", "enum", "properties", "required",
//     "items", "minimum", "maximum", "minLength", "maxLength", "format" (date,
//     date-time, etc). El resto se ignora silenciosamente — verificá los
//     schemas de las tools si hay comportamiento raro.

import type { Tool } from "../tools/base.ts";
import type { GeminiFunctionDeclaration } from "./types.ts";

/**
 * Convierte una Tool del registry interno al formato `function_declarations`
 * de Gemini API.
 *
 * Lanza si `tool.description` está vacío (Gemini lo requiere para decidir
 * cuándo invocar la función).
 */
export function toolToGeminiDeclaration(tool: Tool): GeminiFunctionDeclaration {
  if (!tool.description || tool.description.trim().length === 0) {
    throw new Error(`Tool ${tool.name} no tiene description`);
  }
  return {
    name: tool.name,
    description: tool.description,
    parameters: tool.parameters as Record<string, unknown>,
  };
}

/** Convenience: mapea un array de Tools de una. */
export function toolsToGeminiDeclarations(
  tools: Tool[],
): GeminiFunctionDeclaration[] {
  return tools.map(toolToGeminiDeclaration);
}

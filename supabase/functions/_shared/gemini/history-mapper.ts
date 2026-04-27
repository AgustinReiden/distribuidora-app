// Helpers para appendear turnos al history Gemini-shape.
//
// Como `bot_conversaciones.mensajes` ya guarda el shape `GeminiContent`
// directo (ver memory.ts), este módulo no hace mapping — solo expone funciones
// inmutables para construir el siguiente history sin mutar el anterior.
// Mantenerlas en un módulo aparte ayuda a documentar la regla "cada turno
// nuevo = un push al final" y a centralizar los detalles de la API de Gemini
// (ej: el rol "user" cuando enviamos un functionResponse — peculiaridad de la
// spec).

import type { GeminiContent, GeminiPart } from "./types.ts";

/** Append de un mensaje del usuario en lenguaje natural. */
export function appendUserText(
  history: GeminiContent[],
  text: string,
): GeminiContent[] {
  return [...history, { role: "user", parts: [{ text }] }];
}

/**
 * Append de las parts emitidas por el modelo en una respuesta. Pueden ser
 * text-only, function-call-only, o un mix. Se conservan tal cual para que el
 * próximo turn-of-thought tenga el contexto completo.
 */
export function appendModelParts(
  history: GeminiContent[],
  parts: GeminiPart[],
): GeminiContent[] {
  return [...history, { role: "model", parts }];
}

/**
 * Append del resultado de una tool. OJO: la spec de Gemini exige que el
 * functionResponse vaya con role "user" — no es un typo; conceptualmente, "el
 * usuario (entorno) le devuelve un dato a la conversación".
 *
 * `response` es un objeto libre. Convención del agente: `{result: ...}` para
 * éxito y `{error: "msg"}` para fallos controlados — el modelo aprende a
 * formatear la respuesta apropiada.
 */
export function appendFunctionResponse(
  history: GeminiContent[],
  name: string,
  response: Record<string, unknown>,
): GeminiContent[] {
  return [
    ...history,
    {
      role: "user",
      parts: [{ functionResponse: { name, response } }],
    },
  ];
}

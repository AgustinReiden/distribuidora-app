// Memoria conversacional del bot. Persiste el history Gemini-shape en la tabla
// `bot_conversaciones` (PK telegram_user_id, JSONB `mensajes`).
//
// Convención del JSONB: array de turnos donde cada turno tiene exactamente la
// misma forma que `GeminiContent` (`{role, parts}`). Esto evita un mapper
// intermedio en read/write — al cargar lo pasamos directo al `contents` del
// próximo `callGemini`.
//
// Cap del history:
//   * MAX_TURNS=12 turnos en memoria (se trunca antes de save).
//   * El CHECK constraint en DB (migration 016) es 50 — el cap de la app es
//     más bajo para mantener latencia/tokens razonables.
//   * El truncate preserva emparejamientos: si tras cortar quedó un
//     `functionResponse` huérfano al inicio (sin su `functionCall` previo),
//     descartamos hasta el primer turno "user con texto plano".

import type { SupabaseClient } from "@supabase/supabase-js";
import type { GeminiContent } from "./types.ts";
import { isTextPart } from "./types.ts";

const MAX_TURNS = 12;

/**
 * Carga el history previo del usuario. Retorna [] si no hay fila o si el
 * JSONB tiene shape inesperado (defensivo: cualquier turno malformado se
 * filtra).
 */
export async function loadConversation(
  supabase: SupabaseClient,
  telegram_user_id: number,
): Promise<GeminiContent[]> {
  const { data, error } = await supabase
    .from("bot_conversaciones")
    .select("mensajes")
    .eq("telegram_user_id", telegram_user_id)
    .maybeSingle();

  if (error) {
    throw new Error(`loadConversation: ${error.message}`);
  }
  if (!data) return [];

  const arr = (data as { mensajes: unknown }).mensajes;
  if (!Array.isArray(arr)) return [];

  // Validar shape mínima de cada turn antes de usarlo en el loop.
  const cleaned = arr.filter((t): t is GeminiContent => {
    if (typeof t !== "object" || t === null) return false;
    const turn = t as { role?: unknown; parts?: unknown };
    if (turn.role !== "user" && turn.role !== "model") return false;
    if (!Array.isArray(turn.parts)) return false;
    return true;
  });

  // Sanear el arranque: si una escritura previa dejó el history empezando con
  // un `functionResponse` huérfano (ej: se truncó una conversación con muchas
  // tool calls y quedaron los responses sin sus calls), Gemini rechaza TODO el
  // turno con 400 "function response turn comes immediately after a function
  // call turn". Y como ese turno crashea ANTES de re-guardar un history sano,
  // la fila queda atascada y el bot deja de responderle a ese usuario para
  // siempre. Descartar el arranque inválido en la carga auto-cura ese estado.
  return dropToValidStart(cleaned);
}

/**
 * Persiste el history. Trunca a MAX_TURNS antes de insertar para respetar el
 * CHECK constraint y minimizar storage. Usa upsert sobre la PK.
 */
export async function saveConversation(
  supabase: SupabaseClient,
  telegram_user_id: number,
  history: GeminiContent[],
): Promise<void> {
  const truncated = truncateHistory(history, MAX_TURNS);
  const { error } = await supabase
    .from("bot_conversaciones")
    .upsert(
      {
        telegram_user_id,
        mensajes: truncated,
        actualizado_at: new Date().toISOString(),
      },
      { onConflict: "telegram_user_id" },
    );
  if (error) {
    throw new Error(`saveConversation: ${error.message}`);
  }
}

/**
 * Descarta turnos desde el frente hasta que el history empiece en un punto
 * VÁLIDO para Gemini: un turno `user` cuyas parts son TODAS de texto (el
 * comienzo natural de un intercambio del usuario).
 *
 * Esto garantiza la invariante que Gemini exige —un `functionResponse` (que va
 * en un turno con role "user") SIEMPRE debe venir inmediatamente después de un
 * `functionCall` (turno "model")— evitando el error 400 "function response
 * turn comes immediately after a function call turn" cuando el history quedó
 * con un `functionResponse` huérfano al frente.
 *
 * Si NINGÚN turno es un "user text turn", devuelve [] — arrancar sin contexto
 * es infinitamente preferible a mandar un history que rompe TODAS las
 * respuestas del usuario de forma permanente.
 */
export function dropToValidStart(history: GeminiContent[]): GeminiContent[] {
  for (let i = 0; i < history.length; i++) {
    const t = history[i];
    if (
      t.role === "user" &&
      t.parts.length > 0 &&
      t.parts.every((p) => isTextPart(p))
    ) {
      return i === 0 ? history : history.slice(i);
    }
  }
  return [];
}

/**
 * Trunca el history a los últimos N turnos y garantiza SIEMPRE un arranque
 * válido para Gemini. Tras cortar al tail, `dropToValidStart` descarta
 * cualquier `functionResponse` huérfano que haya quedado al frente (o devuelve
 * [] si el tail entero es tool-call sin un "user text turn" — el caso
 * patológico que antes se persistía roto y dejaba al usuario atascado).
 *
 * El saneo corre aun cuando no hace falta recortar (`length <= maxTurns`): un
 * history sano queda intacto (`dropToValidStart` devuelve el mismo arranque),
 * así que es barato y hace que la función nunca persista un arranque inválido.
 */
export function truncateHistory(
  history: GeminiContent[],
  maxTurns: number,
): GeminiContent[] {
  const tail = history.length <= maxTurns
    ? history
    : history.slice(history.length - maxTurns);
  return dropToValidStart(tail);
}

/** Para tests: expone el cap. */
export const _MAX_TURNS_FOR_TESTS = MAX_TURNS;

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
  return arr.filter((t): t is GeminiContent => {
    if (typeof t !== "object" || t === null) return false;
    const turn = t as { role?: unknown; parts?: unknown };
    if (turn.role !== "user" && turn.role !== "model") return false;
    if (!Array.isArray(turn.parts)) return false;
    return true;
  });
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
 * Trunca el history a los últimos N turnos manteniendo emparejamientos
 * coherentes. Si el primer turno del tail empieza con un functionResponse
 * (huérfano sin su functionCall correspondiente), descartamos hasta encontrar
 * el primer turno "user" con texto plano.
 *
 * Edge cases:
 *   * `history.length <= maxTurns` → retorna tal cual.
 *   * Si NINGÚN turno del tail es "user con texto plano", retornamos el
 *     tail original — preferimos un history un poco roto a uno vacío que
 *     pierda el contexto.
 */
export function truncateHistory(
  history: GeminiContent[],
  maxTurns: number,
): GeminiContent[] {
  if (history.length <= maxTurns) return history;
  const tail = history.slice(history.length - maxTurns);

  // Buscar el primer turno user-only-text. Si existe, cortamos desde ahí —
  // sino dejamos el tail tal cual (evita devolver [] y perder TODO el contexto).
  for (let i = 0; i < tail.length; i++) {
    const t = tail[i];
    if (t.role === "user" && t.parts.every((p) => isTextPart(p))) {
      return i === 0 ? tail : tail.slice(i);
    }
  }
  return tail;
}

/** Para tests: expone el cap. */
export const _MAX_TURNS_FOR_TESTS = MAX_TURNS;

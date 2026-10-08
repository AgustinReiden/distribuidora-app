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
import { type BotRol, rolesDe } from "../types.ts";

const MAX_TURNS = 12;

/**
 * De quién es la memoria (mig 296). La memoria guarda resultados crudos de
 * herramientas: si el chat pasa a otro perfil, o el perfil cambia de roles
 * (un admin al que bajan a preventista) o de sucursal (se la sacan, o un
 * admin cambia con /sucursal), lo que quedó ahí lo vio otra identidad y el
 * modelo se lo podría repetir. Si no coincide, se descarta.
 */
export interface IdentidadMemoria {
  perfil_id: string;
  /** Roles ordenados y sucursal, p.ej. "preventista,transportista@2". */
  firma: string;
}

export function identidadDe(
  u: {
    perfil_id: string;
    rol: BotRol;
    roles?: ReadonlyArray<BotRol>;
    sucursal_id: number | null;
  },
): IdentidadMemoria {
  return { perfil_id: u.perfil_id, firma: `${rolesDe(u).join(",")}@${u.sucursal_id ?? "-"}` };
}

/**
 * Carga el history previo del usuario. Retorna [] si no hay fila o si el
 * JSONB tiene shape inesperado (defensivo: cualquier turno malformado se
 * filtra).
 */
export async function loadConversation(
  supabase: SupabaseClient,
  telegram_user_id: number,
  identidad: IdentidadMemoria,
): Promise<GeminiContent[]> {
  const { data, error } = await supabase
    .from("bot_conversaciones")
    .select("mensajes, perfil_id, firma")
    .eq("telegram_user_id", telegram_user_id)
    .maybeSingle();

  if (error) {
    throw new Error(`loadConversation: ${error.message}`);
  }
  if (!data) return [];

  const fila = data as { mensajes: unknown; perfil_id: unknown; firma: unknown };
  // Una fila sin dueño (anterior a la 296) tampoco coincide: no se sabe con
  // qué roles se escribió. Se pierde el contexto una vez y listo.
  if (fila.perfil_id !== identidad.perfil_id || fila.firma !== identidad.firma) {
    return [];
  }

  const arr = fila.mensajes;
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
  identidad: IdentidadMemoria,
): Promise<void> {
  const truncated = compactarRespuestas(truncateHistory(history, MAX_TURNS));
  const { error } = await supabase
    .from("bot_conversaciones")
    .upsert(
      {
        telegram_user_id,
        mensajes: truncated,
        perfil_id: identidad.perfil_id,
        firma: identidad.firma,
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

/**
 * Tope de lo que se guarda de cada resultado de herramienta (#979, C2 del
 * plan). Una ficha o un ranking crudos pesan miles de tokens y se re-mandan en
 * CADA turno siguiente: eran la mitad de la entrada de una consulta típica. De
 * la memoria alcanza con el principio; si el modelo necesita el dato exacto
 * otra vez, vuelve a llamar a la herramienta (el prompt se lo dice).
 */
export const MAX_CHARS_RESULTADO_EN_MEMORIA = 1200;

/**
 * Recorta los resultados de herramientas largos antes de guardar. No toca las
 * llamadas del modelo (ahí vive la firma de razonamiento de Gemini 3.x) ni el
 * texto: sólo el `response` de cada functionResponse.
 */
export function compactarRespuestas(history: GeminiContent[]): GeminiContent[] {
  return history.map((turno) => {
    if (turno.role !== "user" || !turno.parts.some((p) => "functionResponse" in p)) return turno;
    return {
      ...turno,
      parts: turno.parts.map((p) => {
        if (!("functionResponse" in p)) return p;
        const json = JSON.stringify(p.functionResponse.response);
        if (json.length <= MAX_CHARS_RESULTADO_EN_MEMORIA) return p;
        return {
          functionResponse: {
            name: p.functionResponse.name,
            response: {
              recortado: true,
              inicio: json.slice(0, MAX_CHARS_RESULTADO_EN_MEMORIA),
            },
          },
        };
      }),
    };
  });
}

/** Para tests: expone el cap. */
export const _MAX_TURNS_FOR_TESTS = MAX_TURNS;
